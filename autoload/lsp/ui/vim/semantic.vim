let s:use_vim_textprops = lsp#utils#_has_textprops() && !has('nvim')
let s:use_nvim_highlight = exists('*nvim_buf_add_highlight') && has('nvim')
if s:use_nvim_highlight
    let s:namespace_id = nvim_create_namespace('vim-lsp-semantic')
endif

if !hlexists('LspUnknownScope')
    highlight LspUnknownScope gui=NONE cterm=NONE guifg=NONE ctermfg=NONE guibg=NONE ctermbg=NONE
endif

let s:bufnr_highlighted = {}

let s:supported_token_types = [
    \   'namespace',
    \   'type',
    \   'class',
    \   'enum',
    \   'interface',
    \   'struct',
    \   'typeParameter',
    \   'parameter',
    \   'variable',
    \   'property',
    \   'enumMember',
    \   'event',
    \   'function',
    \   'method',
    \   'macro',
    \   'keyword',
    \   'modifier',
    \   'comment',
    \   'string',
    \   'number',
    \   'regexp',
    \   'operator',
    \ ]
let s:supported_token_modifiers = []
    " TODO: support these
    " \ [
    " \   'declaration',
    " \   'definition',
    " \   'readonly',
    " \   'static',
    " \   'deprecated',
    " \   'abstract',
    " \   'async',
    " \   'modification',
    " \   'documentation',
    " \   'defaultLibrary',
    " \ ]

function! lsp#ui#vim#semantic#get_default_supported_token_types() abort
    return s:supported_token_types
endfunction

function! lsp#ui#vim#semantic#get_default_supported_token_modifiers() abort
    return s:supported_token_modifiers
endfunction

function! lsp#ui#vim#semantic#is_enabled() abort
    return g:lsp_semantic_enabled && (s:use_vim_textprops || s:use_nvim_highlight) ? v:true : v:false
endfunction

function! lsp#ui#vim#semantic#get_legend(server) abort
    if !lsp#capabilities#has_semantic_tokens(a:server)
        return []
    endif

    let l:capabilities = lsp#get_server_capabilities(a:server)
    return l:capabilities['semanticTokensProvider']['legend']
endfunction

function! lsp#ui#vim#semantic#do_semantic_highlight() abort
    let l:bufnr = bufnr('%')
    let l:servers = s:get_supported_servers()

    if len(l:servers) == 0
        call lsp#utils#error('Semantic tokens not supported for ' . &filetype)
        return
    endif

    let l:server = l:servers[0]
    call lsp#send_request(l:server, {
    \   'method': 'textDocument/semanticTokens/full',
    \   'params': {
    \       'textDocument': lsp#get_text_document_identifier(),
    \   },
    \   'on_notification': function('s:handle_full_semantic_highlight', [l:server, l:bufnr]),
    \ })
endfunction

function! lsp#ui#vim#semantic#display_token_types() abort
    let l:servers = s:get_supported_servers()

    if len(l:servers) == 0
        call lsp#utils#error('Semantic tokens not supported for ' . &filetype)
        return
    endif

    let l:server = l:servers[0]
    let l:info = lsp#get_server_info(l:server)
    let l:highlight_mappings = get(l:info, 'semantic_highlight', {})
    let l:legend = lsp#ui#vim#semantic#get_legend(l:server)
    let l:token_types = uniq(sort(copy(l:legend['tokenTypes'])))

    for l:token_type in l:token_types
        if has_key(l:highlight_mappings, l:token_type)
            execute 'echohl ' . l:highlight_mappings[l:token_type]
        endif
        echo l:token_type
        echohl None
    endfor
endfunction

function! s:handle_full_semantic_highlight(server, bufnr, data) abort
    let l:start_time = reltimefloat(reltime())
    let l:lap_start = reltimefloat(reltime())

    call lsp#log('semantic token: got semantic tokens!')
    if !g:lsp_semantic_enabled | return | endif

    if lsp#client#is_error(a:data['response'])
        call lsp#log('Skipping semantic token: response is invalid')
        return
    endif

    " Skip if the buffer doesn't exist. This might happen when a buffer is
    " opened and quickly deleted.
    if !bufloaded(a:bufnr) | return | endif

    let l:lap_end = reltimefloat(reltime())
    call lsp#log('check seconds:', l:lap_end - l:lap_start)
    let l:lap_start = reltimefloat(reltime())

    call s:init_highlight(a:server, a:bufnr)

    let l:lap_end = reltimefloat(reltime())
    call lsp#log('initialization seconds:', l:lap_end - l:lap_start)
    let l:lap_start = reltimefloat(reltime())

    let l:data = s:ensure_dict_path(a:data, ['response', 'result', 'data'], type([]))
    if s:is_null(l:data)
        call lsp#log('Skipping semantic tokens: server returned nothing or invalid data')
        return
    endif

    call lsp#log('semantic tokens: do semantic highlighting')
    let l:num_lines = len(getbufline(a:bufnr, 1, '$'))

    let l:lap_end = reltimefloat(reltime())
    call lsp#log('got lines seconds:', l:lap_end - l:lap_start)
    let l:lap_start = reltimefloat(reltime())

    let l:curr_highlights = s:parse_semantic_tokens(a:server, l:data)
    if s:is_null(l:curr_highlights)
        call lsp#log('Skipping semantic tokens: server returned invalid semantic tokens')
        return
    endif

    let l:lap_end = reltimefloat(reltime())
    call lsp#log('parsing semantic tokens seconds:', l:lap_end - l:lap_start)
    let l:lap_start = reltimefloat(reltime())

    let l:prev_highlights = s:get_highlights(a:bufnr)

    let l:lap_end = reltimefloat(reltime())
    call lsp#log('getting current highlight seconds', l:lap_end - l:lap_start)
    let l:lap_start = reltimefloat(reltime())

    let l:to_update = s:calc_diff(l:prev_highlights, l:curr_highlights, l:num_lines)
    " call lsp#log("highlight updates:", l:to_update)
    for [l:line, l:highlights] in l:to_update
        call s:remove_highlight(a:bufnr, l:line)
        for l:hl in l:highlights
            call s:add_highlight(a:bufnr, l:hl)
        endfor
    endfor

    let l:lap_end = reltimefloat(reltime())
    call lsp#log('adding highlights seconds:', l:lap_end - l:lap_start)
    let l:lap_start = reltimefloat(reltime())

    let s:bufnr_highlighted[a:bufnr] = 1

    let l:end_time = reltimefloat(reltime())
    call lsp#log('Entire highlighting seconds:', l:end_time - l:start_time)
endfunction

function! s:get_supported_servers() abort
    return filter(lsp#get_allowed_servers(), 'lsp#capabilities#has_semantic_tokens(v:val)')
endfunction

function! s:ensure_dict_path(dic, path, target_type) abort
    let l:current = a:dic
    for value in a:path
        if type(l:current) != type({})
            return v:null
        endif
        if !has_key(l:current, value)
            return v:null
        endif
        let l:current = l:current[value]
    endfor
    if a:target_type != v:null && type(l:current) != a:target_type
        return v:null
    endif
    return l:current
endfunction

function! s:is_null(v) abort
    return type(a:v) == type(v:null) && a:v == v:null
endfunction

function! s:parse_semantic_tokens(server, data) abort
    let l:num_data = len(a:data)
    if l:num_data % 5 != 0
        call lsp#log(printf('Skipping semantic token: invalid number of data (%d) returned', l:num_data))
        return v:null
    endif

    let l:res = {}
    let l:legend = lsp#ui#vim#semantic#get_legend(a:server)
    let l:current_line = 0
    let l:current_char = 0
    for l:idx in range(0, l:num_data - 1, 5)
        let l:delta_line = a:data[l:idx]
        let l:delta_start_char = a:data[l:idx + 1]
        let l:length = a:data[l:idx + 2]
        let l:token_type = a:data[l:idx + 3]
        " TODO: support token modifiers
        " let l:token_modifiers = a:data[l:idx + 4]

        " Calculate the absolute position from relative coordinates
        let l:line = l:current_line + l:delta_line
        let l:char = l:delta_line == 0 ? l:current_char + l:delta_start_char : l:delta_start_char
        let l:current_line = l:line
        let l:current_char = l:char

        if !has_key(l:res, l:line)
            let l:res[l:line] = []
        endif

        call add(l:res[l:line], {
          \     'line': l:line,
          \     'start_char': l:char,
          \     'end_char': l:char + l:length,
          \     'group': s:token_type_to_highlight(a:server, l:legend['tokenTypes'][l:token_type]),
          \ })
    endfor

    return l:res
endfunction

function! s:token_type_to_highlight(server, token_type) abort
    try
        let l:info = lsp#get_server_info(a:server)
        let l:highlight = l:info['semantic_highlight']
        if has_key(l:highlight, a:token_type)
            return l:highlight[a:token_type]
        endif
    catch
    endtry
    return 'LspUnknownScope'
endfunction

function! s:compare_highlights(a, b) abort
    if a:a['line'] != a:b['line']
        return a:a['line'] - a:b['line']
    endif
    if a:a['start_char'] != a:b['start_char']
        return a:a['start_char'] != a:b['start_char']
    endif
    if a:a['end_char'] != a:b['end_char']
        return a:a['end_char'] != a:b['end_char']
    endif
    return 0
endfunction

function! s:calc_diff(prev_highlights, curr_highlights, num_lines) abort
    let l:lnums_to_update = []
    for l:i in range(a:num_lines)
        let l:ph = has_key(a:prev_highlights, l:i)
        let l:ch = has_key(a:curr_highlights, l:i)

        if (!l:ph && l:ch) || (l:ph && !l:ch)
            call add(l:lnums_to_update, l:i)
            continue
        endif

        if !l:ph && !l:ch
            continue
        endif

        let l:pp = a:prev_highlights[l:i]
        let l:cc = a:curr_highlights[l:i]
        if len(l:pp) != len(l:cc)
            call add(l:lnums_to_update, l:i)
            continue
        endif

        call sort(l:pp)
        call sort(l:cc)
        for l:j in range(len(l:pp))
            if s:compare_highlights(l:pp[l:j], l:cc[l:j]) != 0
                call add(l:lnums_to_update, l:i)
                break
            endif
        endfor
    endfor

    let l:res = []
    for l:i in l:lnums_to_update
        call add(l:res, [l:i, get(a:curr_highlights, l:i, [])])
    endfor
    return l:res
endfunction

function! s:init_highlight(server, buf) abort
    if !empty(getbufvar(a:buf, 'lsp_did_semantic_setup'))
        return
    endif
    if s:use_vim_textprops
        let l:token_types = lsp#ui#vim#semantic#get_legend(a:server)['tokenTypes']
        for l:token_type in l:token_types
            let l:highlight = s:token_type_to_highlight(a:server, l:token_type)
            silent! call prop_type_add(l:highlight, {'bufnr': a:buf, 'highlight': l:highlight, 'combine': v:true})
        endfor
        silent! call prop_type_add(s:textprop_cache, {'bufnr': a:buf})
    endif
    call setbufvar(a:buf, 'lsp_did_semantic_setup', 1)
endfunction

" Vim/Neovim highlight API {{{
function! s:get_highlights(bufnr) abort
    let l:lines = len(getbufline(a:bufnr, 1, '$'))
    let l:res = {}
    if s:use_vim_textprops
        for l:line in range(l:lines)
            let l:list = prop_list(l:line + 1, {'bufnr': a:bufnr})
            for l:prop in l:list
                if l:prop['start'] == 0 || l:prop['end'] == 0
                    " multi line tokens are not supported; simply ignore it
                    continue
                endif

                let l:group = l:prop['type']
                let l:start = l:prop['col'] - 1
                let l:end = l:start + l:prop['length']
                if !has_key(l:res, l:line) | let l:res[l:line] = [] | endif
                call add(l:res[l:line], {
                  \     'line': l:line,
                  \     'start_char': l:start,
                  \     'end_char': l:end,
                  \     'group': l:group,
                  \ })
            endfor
        endfor
    elseif s:use_nvim_highlight
        let l:marks = nvim_buf_get_extmarks(
          \     a:bufnr,
          \     s:namespace_id,
          \     0,
          \     -1,
          \     {'details': v:true}
          \ )
        for [_, l:line, l:start, l:details] in l:marks
            if !has_key(l:res, l:line) | let l:res[l:line] = [] | endif
            call add(l:res[l:line], {
              \     'line': l:line,
              \     'start_char': l:start,
              \     'end_char': l:details['end_col'],
              \     'group': l:details['hl_group'],
              \ })
        endfor
    endif

    return l:res
endfunction

function! s:add_highlight(bufnr, hl) abort
    if s:use_vim_textprops
        let l:type = a:hl['group']
        let l:line = a:hl['line'] + 1
        let l:start = a:hl['start_char'] + 1
        let l:end = a:hl['end_char'] + 1
        call prop_add(l:line, l:start, {
          \     'end_lnum': l:line,
          \     'end_col': l:end,
          \     'bufnr': a:bufnr,
          \     'type': l:type
          \ })
    elseif s:use_nvim_highlight
        let l:group = a:hl['group']
        let l:line = a:hl['line']
        let l:start = a:hl['start_char']
        let l:end = a:hl['end_char']
        call nvim_buf_add_highlight(
          \     a:bufnr,
          \     s:namespace_id,
          \     l:group,
          \     l:line,
          \     l:start,
          \     l:end
          \ )
    endif
endfunction

function! s:remove_highlight(bufnr, line) abort
    if s:use_vim_textprops
        call prop_clear(a:line + 1, a:line + 1, {'bufnr': a:bufnr})
    elseif s:use_vim_textprops
        call nvim_buf_clear_namespace(a:bufnr, s:namespace_id, a:line, a:line + 1)
    endif
endfunction

function! s:clear_highlights(bufnr) abort
  if s:use_vim_textprops
    let l:lines = len(getbufline(a:bufnr, 1, '$'))
    call prop_clear(1, l:lines, {'bufnr': a:bufnr})
  elseif s:use_nvim_highlight
    call nvim_buf_clear_namespace(a:bufnr, s:namespace_id, 0, -1)
  endif
endfunction
"}}}

function! lsp#ui#vim#semantic#setup() abort
    augroup _lsp_semantic_tokens
        autocmd!
        autocmd BufEnter,CursorHold,CursorHoldI * if len(s:get_supported_servers()) > 0 | call lsp#ui#vim#semantic#do_semantic_highlight() | endif
    augroup END
endfunction

function! lsp#ui#vim#semantic#_disable() abort
    augroup _lsp_semantic_tokens
        autocmd!
    augroup END
    for l:bufnr in keys(s:bufnr_highlighted)
        call s:clear_highlights(l:bufnr)
    endfor
    let s:bufnr_highlighted = {}
endfunction

" vim: fdm=marker sw=4
