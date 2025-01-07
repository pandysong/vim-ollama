" autoload/ollama.vim
" SPDX-License-Identifier: GPL-3.0-or-later
" SPDX-CopyrightText: 2024 Gerhard Gappmeier <gappy1502@gmx.net>
" SPDX-CopyrightTdxt: Copyright (C) 2023 GitHub, Inc. - All Rights Reserved
" This file started as a copy of copilot.vim but was rewritten entirely,
" because of the different concept of talking with Ollama instead of MS
" copilot. Still it can contain tiny fragments of the original code.
scriptencoding utf-8

" Retrives the list of installed Ollama models
function! ollama#setup#GetModels(url)
    " Construct the shell command to call list_models.py with the provided URL
    let l:script_path = printf('%s/python/list_models.py', expand('<script>:h:h:h'))
    let l:command = 'python3 ' .. l:script_path .. ' -u ' .. shellescape(a:url)

    " Execute the shell command and capture the output
    let l:output = system(l:command)

    " Check for errors during the execution
    if v:shell_error != 0
        echom "Error: Failed to fetch models from " . a:url
        echoerr "Output: " . l:output
        return [ 'error' ]
    endif

    " Split the output into lines and return as a list
    return split(l:output, "\n")
endfunction

" Process Pull Model stdout
function! s:PullOutputCallback(job_id, data)
    if !empty(a:data)
        call ollama#logger#Debug("Pull Output: " . a:data)
        let l:output = split(a:data, '\\n')

        " Update the popup with progress
        if exists('s:popup_id') && s:popup_id isnot v:null
            call popup_settext(s:popup_id, l:output)
        endif
    endif
endfunction

" Process Pull Model stderr
function! s:PullErrorCallback(job_id, data)
    if !empty(a:data)
        " Log the error
        call ollama#logger#Error("Pull Error: " . a:data)
        let l:output = split(a:data, '\\n')

        " Display the error in the popup
        if exists('s:popup_id') && s:popup_id isnot v:null
            call popup_settext(s:popup_id, 'Error: ' . l:output)
        endif
    endif
endfunction

" Deferred close of progress popup window
function! s:ClosePopup(timer_id)
    call popup_close(s:popup_id)
    let s:popup_id = v:null
    " Continue with setup process
    call s:ExecuteNextSetupTask()
endfunction

" Process pull process exit code
function! s:PullExitCallback(job_id, exit_code)
    call ollama#logger#Debug("PullExitCallback: ". a:exit_code)
    if a:exit_code == 0
        " Log success
        call ollama#logger#Debug("Pull job completed successfully.")

        " Update the popup with success message
        if exists('s:popup_id') && s:popup_id isnot v:null
            call popup_settext(s:popup_id, 'Model pull completed successfully!')
        endif
    else
        " Log failure
        call ollama#logger#Error("Pull job failed with exit code: " . a:exit_code)

        " Update the popup with failure message
        if exists('s:popup_id') && s:popup_id isnot v:null
            call popup_settext(s:popup_id, 'Model pull failed. See logs for details.')
        endif
    endif

    " Close the popup after a delay
    if exists('s:popup_id') && s:popup_id isnot v:null
        call timer_start(2000, function('s:ClosePopup'))
    endif

    " Clear the pull job reference
    let s:pull_job = v:null
endfunction

" Pulls the given model in Ollama asynchronously
function! ollama#setup#PullModel(url, model)
    " Construct the shell command to call the Python script
    let l:script_path = printf('%s/python/pull_model.py', expand('<script>:h:h:h'))
    let l:command = ['python3', l:script_path, '-u', shellescape(a:url), '-m', shellescape(a:model)]

    " Log the command being run
    call ollama#logger#Debug("command=". join(l:command, " "))

    " Define job options
    let l:job_options = {
                \ 'in_mode': 'nl',
                \ 'out_mode': 'nl',
                \ 'err_mode': 'nl',
                \ 'out_cb': function('s:PullOutputCallback'),
                \ 'err_cb': function('s:PullErrorCallback'),
                \ 'exit_cb': function('s:PullExitCallback')
                \ }

    " Kill any running pull job and replace with new one
    if exists('s:pull_job') && s:pull_job isnot v:null
        call ollama#logger#Debug("Terminating existing pull job.")
        call job_stop(s:pull_job)
    endif

    " Create a popup window for progress
    let s:popup_id = popup_dialog('Pulling model: ' . a:model . '\n', {
                \ 'padding': [0, 1, 0, 1],
                \ 'zindex': 1000
                \ })

    " Save the popup ID for updates in callbacks
    let s:popup_model = a:model

    " Start the new job and keep a reference to it
    call ollama#logger#Debug("Starting pull job for model: " . a:model)
    let s:pull_job = job_start(l:command, l:job_options)
endfunction

" Main Setup routine which helps the user to get started
function! ollama#setup#Setup()
    " setup default local URL
    let g:ollama_host = "http://localhost:11434"
    let g:ollama_host = "http://tux:11434"
    let l:ans = input("The default Ollama base URL is '" . g:ollama_host . "'. Do you want to change it? (y/N): ")
    if tolower(l:ans) == 'y'
        let g:ollama_host = input("Enter Ollama base URL: ")
    endif
    echon "\n"

    " get all available models (and test if connection works)
    let l:models = ollama#setup#GetModels(g:ollama_host)

    " create async tasks
    let s:setup_tasks = [function('s:PullCompletionModelTask'), function('s:PullChatModelTask'), function('s:FinalizeSetupTask')]
    let s:current_task = 2 " start with Finalize if no pulling is required

    if !empty(l:models)
        if l:models[0] == 'error'
            return
        endif
        " Display available models to the user
        echon "Available Models:\n"
        let l:idx = 1
        for l:model in l:models
            echon "  [" .. l:idx .. "] " .. l:model .. "\n"
            let l:idx += 1
        endfor
        echon "\n"
        " Select tab completion model
        while 1
            let l:ans = input("Choose tab completion model: ")
            echon "\n"
            " Check if input is a number
            if l:ans =~ '^\d\+$'
                let l:ans = str2nr(l:ans)
                " Check range
                if l:ans > 0 && l:ans <= len(l:models)
                    let g:ollama_model = l:models[l:ans - 1]
                    echo "Configured '" . g:ollama_model . "' as tab completion model.\n"
                    break
                endif
            endif
            echo "error: invalid index"
        endwhile
        " Select chat model
        while 1
            let l:ans = input("Choose chat model: ")
            echon "\n"
            " Check if input is a number
            if l:ans =~ '^\d\+$'
                let l:ans = str2nr(l:ans)
                " Check range
                if l:ans > 0 && l:ans <= len(l:models)
                    let g:ollama_chat_model = l:models[l:ans - 1]
                    echo "Configured '" . g:ollama_chat_model . "' as chat model.\n"
                    break
                endif
            endif
            echo "error: invalid index"
        endwhile
    else
        let l:ans = input("No models found. Should I load a sane default configuration? (Y/n): ")
        if tolower(l:ans) != 'n'
            let s:current_task = 0
        endif
    endif

    call s:ExecuteNextSetupTask()
endfunction

function! s:PullCompletionModelTask()
    " Set the default tab completion model
    let g:ollama_model = "qwen2.5-coder:1.5b"
    call ollama#setup#PullModel(g:ollama_host, g:ollama_model)
endfunction

function! s:PullChatModelTask()
    " Set the default chat model
    let g:ollama_chat_model = "llama3.1:8b"
    call ollama#setup#PullModel(g:ollama_host, g:ollama_chat_model)
endfunction

" Finalize setup task is called after all setup tasks are completed
" This creates the ollama.vim config file.
function! s:FinalizeSetupTask()
    " Save the URL to a configuration file
    let l:config_dir = expand('~/.vim/config')
    if !isdirectory(l:config_dir)
        call mkdir(l:config_dir, 'p') " Create the directory if it doesn't exist
    endif
    let l:config_file = l:config_dir . '/ollama.vim'

    " Write the configuration to the file
    let l:config = [
                \ "\" Ollama base URL",
                \ "let g:ollama_host = '" . g:ollama_host . "'",
                \ "\" tab completion model",
                \ "let g:ollama_model = '" . g:ollama_model . "'",
                \ "\" chat model",
                \ "let g:ollama_chat_model = '" . g:ollama_chat_model . "'" ]
    call writefile(l:config, l:config_file)
    echon "Configuration saved to " . l:config_file . "\n"
    call popup_notification("Setup complete", #{ pos: 'center'})
endfunction

" Function to execute the next task
function! s:ExecuteNextSetupTask()
    if s:setup_tasks == v:null
        return
    endif
    if s:current_task < len(s:setup_tasks)
        " Get the current task function and execute it
        let l:Task = s:setup_tasks[s:current_task]
        let s:current_task = s:current_task + 1
        call call(l:Task, [])
    else
        " All tasks are completed
        let s:setup_taks = v:null
    endif
endfunction

function ollama#setup#Init()
    " check if config file exists
    if !filereadable(expand('~/.vim/config/ollama.vim'))
        echon "Welcome to Vim-Ollama!\n"
        echon "----------------------\n"
        let l:ans = input("This is the first time you are using this plugin. Should I help you setting up everything? (Y/n): ")
        if tolower(l:ans) == 'n'
            return
        endif
        echon "\n"

        call ollama#setup#Setup()
    else
        " load the config file
        source ~/.vim/config/ollama.vim
    endif
endfunction

call ollama#setup#Init()
