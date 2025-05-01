local libnotify = require 'libnotify'

local NOTIFICATION_TITLE = "kokoro.nvim"
local notifier = nil

local rex = require('rex_pcre')

local FEMALE=0
local MALE=1

local function write_to_file(filename, text)
    -- Open file in write mode ("w" overwrites, "a" appends)
    local file, err = io.open(filename, "w")
    if not file then
        notifier.error("Error opening file: " .. (err or "unknown error"))
        return false
    end

    -- Write text to the file
    file:write(text)

    -- Close the file
    file:close()
    return true
end

local function truncate_string(str, max_len)
    max_len = max_len or 20  -- Default to 20 if not specified

    if type(str) ~= "string" then
        return ""  -- Return empty string for non-string input
    end

    if #str <= max_len then
        return str  -- Return original string if it's short enough
    else
        return str:sub(1, max_len) .. "..."  -- Truncate and append "..."
    end
end

local M = {
    clip_id = 0,
    clips = {},

    trans_jobs = {},
    trans_gender_history = {}, -- This is not what it looks like

    voices = {}, -- Voices available for selection (kokoro-tts --help-voices)

    opts = {
        -- Kokoro Runtime
        path = nil,
        uv = false,
        player = "afplay",

        -- Plugin Options
        debug = false,
        notify_min_level = vim.log.levels.INFO,
        workers = 2,
        load_voices = true,
        word_threshold = 15,

        -- Kokoro options
        voice = "af_nicole",
        speed = 1.0,
        male_quote_voice="bm_lewis",
        female_quote_voice="bf_alice",
    },

}

-- Create a Clip object
function M.create_clip(text, voice, speed)
    local clip = {} -- New table for the object

    -- Give each clip a clip_id so that it can be found in the clips
    clip.clip_id = M.clip_id
    M.clip_id = M.clip_id + 1

    -- Members (data)
    clip.text = text
    clip.text_trunc = truncate_string(text, 50)
    clip.voice = voice
    clip.speed = speed

    clip.tts_job_id = 0
    clip.tts_stdout = {}
    clip.tts_stderr = {}
    clip.tts_code = -1

    clip.wav_path = ""

    clip.play_job_id = 0
    clip.play_stdout = {}
    clip.play_stderr = {}

    -- Methods (functions)
    function clip:is_rendering()
        if clip.tts_job_id > 0 then
            if clip.tts_code < 0 then
                return true
            end
        end
        return false
    end
    function clip:is_rendered()
        if clip.tts_code >= 0 then
            return true
        end
        return false
    end

    function clip:is_playing()
        return clip.play_job_id > 0
    end

    return clip
end


function M.play()
    local cmd

    if #M.clips == 0 then
        notifier.info("Finished playing clips")
        return
    end

    -- Skip if a clip is already playing
    if M.clips[1]:is_playing() then
        notifier.trace("Already Playing")
        return
    end
    if not M.clips[1]:is_rendered() then
        notifier.trace("Not ready to play")
        return
    end

    local job_opts = {
        stdin = 'pipe',  -- Enable stdin as a pipe
        on_stdout = function(_, data)
            if data then
                vim.schedule(function()
                    for _, line in ipairs(data) do
                        table.insert(M.clips[1].play_stdout, line)
                    end
                end)
            end
        end,
        on_stderr = function(_, data)
            if data then
                vim.schedule(function()
                    for _,line in ipairs(data) do
                        table.insert(M.clips[1].play_stderr, line)
                    end
                end)
            end
        end,
        on_exit = function(_, code)
            vim.schedule(function()

                if code ~= 0 then
                    notifier.error("Process exited with "..code..".  CMD: "..cmd)
                    if M.opts.debug then
                        notifier.debug("stdout: " .. table.concat(M.clips[1].tts_stdout, "\n"))
                        notifier.debug("stderr: " .. table.concat(M.clips[1].tts_stderr, "\n"))
                    end
                else
                    notifier.info("Finished Playing: "..M.clips[1].text_trunc)
                end

                -- Remove the completed clip.  Assume first is always the one that just finished playing
                table.remove(M.clips, 1)

                -- play the next clip
                M.play()
            end)
        end,
    }

    notifier.info("Playing: "..M.clips[1].text_trunc.." File: "..M.clips[1].wav_path)
    cmd = string.format([[%s "%s"]], M.opts.player, M.clips[1].wav_path)
    M.clips[1].play_job_id = vim.fn.jobstart(cmd, job_opts)
    if M.clips[1].play_job_id <= 0 then
        notifier.error("Error: Failed to start command '" .. cmd .. "'")
        return
    end
end

function M.running_tts_count()
    local count = 0
    for _, clip in ipairs(M.clips) do
        if clip:is_rendering() then
            count = count + 1
        end
    end
    return count
end

function M.clip_to_render()
    for i, clip in ipairs(M.clips) do
        if not clip:is_rendered() then
            if not clip:is_rendering() then
                return i, clip.clip_id
            end
        end
    end
    return -1, -1
end

function M.clip_by_id(id)
    for i, clip in ipairs(M.clips) do
        if clip.clip_id == id then
            return i, clip
        end
    end
    return -1, nil
end

-- See if we can play the next clip
function M.tts()
    -- Limit to two workers
    if M.running_tts_count() >= M.opts.workers then
        notifier.debug("tts worker limit")
        return
    end

    local clip_index, clip_id = M.clip_to_render()
    if clip_index == -1 then
        notifier.debug("no more clips to render")
        return
    end
    local clip = M.clips[clip_index] -- this is NOT a reference!!!

    local cmd
    local job_opts = {
        cwd = M.opts.path,
        on_stdout = function(_, data)
            if data then
                vim.schedule(function()
                    -- This clip may have a different index when this is called
                    local clip_index, clip = M.clip_by_id(clip_id)
                    if clip == nil then
                        notifier.error("tts.on_stdout: Clip is nil")
                    else
                        for _, line in ipairs(data) do
                            table.insert(clip.tts_stdout, line)
                        end
                        M.clips[clip_index] = clip
                    end
                end)
            end
        end,
        on_stderr = function(_, data)
            if data then
                vim.schedule(function()
                    -- This clip may have a different index when this is called
                    local clip_index, clip = M.clip_by_id(clip_id)
                    if clip == nil then
                        notifier.error("tts.on_stderr: Clip is nil")
                    else
                        for _, line in ipairs(data) do
                            table.insert(clip.tts_stderr, line)
                        end
                        M.clips[clip_index] = clip
                    end
                end)
            end
        end,
        on_exit = function(_, code)
            vim.schedule(function()
                -- This clip may have a different index when this is called
                local clip_index, clip = M.clip_by_id(clip_id)
                if clip == nil then
                    notifier.info(string.format("Finished Translating: nil Clip"))
                else
                    M.clips[clip_index].tts_code = code
                    notifier.info(string.format("Finished Translating: %s", clip.text_trunc))
                end

                if code == 0 then

                    M.play()
                else
                    notifier.error("Process exited with "..code..".  CMD: "..cmd)
                    if M.opts.debug then
                        notifier.debug("stdout: " .. table.concat(M.trans_stdout, "\n"))
                        notifier.debug("stderr: " .. table.concat(M.trans_stderr, "\n"))
                    end
                end

                M.tts()
            end)
        end,
    }

    local tts_txt_temp = vim.fn.tempname()

    if not write_to_file(tts_txt_temp, clip.text) then
        notifier.error("Error writing to text tmp file for kokoro")
        return
    end

    local kokoro = M.opts.path.."/kokoro-tts"
    if M.opts.uv then
        kokoro = "uv run "..kokoro
    end

    clip.wav_path = vim.fn.tempname()..".wav"

    cmd = string.format("%s %s %s --speed %f --voice %s", kokoro, tts_txt_temp, clip.wav_path, clip.speed, clip.voice)
    notifier.info(string.format("Translating text: %s", clip.text_trunc))
    clip.tts_job_id = vim.fn.jobstart(cmd, job_opts)
    M.clips[clip_index] = clip -- Update clip with changed values
    if clip.tts_job_id <= 0 then
        notifier.error("Error: Failed to start command '" .. cmd .. "'")
        return
    end
end

-- Add clip to be rendered and played
function M.enqueue(clip)
    table.insert(M.clips,clip)
    M.tts()
end

local function get_selected_text()
    -- getpos returns [bufnum, lnum, col, off]
    -- lnum and col are 1 based
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")

    notifier.trace("start_pos: "..vim.inspect(start_pos))
    notifier.trace("end_pos: "..vim.inspect(end_pos))

    local start_line = start_pos[2]
    local start_col = start_pos[3]

    local end_line = end_pos[2]
    local end_col = end_pos[3]


    notifier.trace("start_line: "..start_line)
    notifier.trace("end_line: "..end_line)

    local selected_text = {}
    -- nvim_buf_get_lines start and end lines are 0 based
    local lines = vim.api.nvim_buf_get_lines(0, start_line-1, end_line, false)
    for no = start_line,end_line do
        local line = lines[no - start_line + 1]
        notifier.trace("Line: "..line)
        if no == start_line then
            if no == end_line then
                notifier.trace("no: "..no)
                notifier.trace("start_line: "..start_line)
                notifier.trace("start_col: "..start_col)
                notifier.trace("end_col: "..end_col)
                table.insert(selected_text, line:sub(start_col, end_col))
            else
                table.insert(selected_text, line:sub(start_col))
            end
        else
            if no == end_line then
                table.insert(selected_text, line:sub(1, end_col))
            else
                table.insert(selected_text, line)
            end
        end
    end
    return table.concat(selected_text, "\n")
end

local function split_sentences(text)
    if type(text) ~= "string" then
        return {}
    end

    -- List of common abbreviations that shouldn't split sentences
    local abbreviations = {
        ["Mr."] = true,
        ["Mrs."] = true,
        ["Ms."] = true,
        ["Dr."] = true,
        ["Prof."] = true,
        ["St."] = true,  -- e.g., Saint or Street
        ["etc."] = true,
        ["vs."] = true,
    }

    local sentences = {}
    local current_sentence = ""
    local i = 1

    while i <= #text do
        local char = text:sub(i, i)
        current_sentence = current_sentence .. char

        -- Check if we're at a potential sentence end (., !, or ?)
        if char:match("[.!?]") then
            -- Peek ahead to see what follows
            local next_pos = i + 1
            local next_char = text:sub(next_pos, next_pos)
            local following_char = text:sub(next_pos + 1, next_pos + 1)

            -- Check if this period might be part of an abbreviation
            local is_abbreviation = false
            for abbr in pairs(abbreviations) do
                local start = i - #abbr + 1
                if start >= 1 and text:sub(start, i) == abbr then
                    is_abbreviation = true
                    break
                end
            end

            -- Sentence ends if:
            -- 1. Not an abbreviation AND
            -- 2. Followed by whitespace and an uppercase letter (or end of text)
            if not is_abbreviation and
                (next_char:match("%s") and following_char:match("%u")) or
                next_pos > #text then
                -- Trim whitespace and add to sentences
                current_sentence = current_sentence:gsub("%s+$", "")
                table.insert(sentences, current_sentence)
                current_sentence = ""
            end
        end

        i = i + 1
    end

    -- Add any remaining text as a sentence if non-empty
    if #current_sentence > 0 then
        current_sentence = current_sentence:gsub("%s+$", "")
        if #current_sentence > 0 then
            table.insert(sentences, current_sentence)
        end
    end

    return sentences
end

local function count_words(str)
    if type(str) ~= "string" then
        return 0  -- Return 0 for non-string input
    end

    local count = 0
    for word in str:gmatch("%S+") do
        count = count + 1
    end

    return count
end


local function group_sentences(sentences)
    local n = 1
    local prev_words = 999

    while n <= #sentences do
        local sentence = sentences[n]
        local words = count_words(sentence)

        if M.opts.debug then
            notifier.debug("words: "..words .. " prev_words: "..prev_words)
        end

        if prev_words < M.opts.word_threshold then
            if words < M.opts.word_threshold then

                if M.opts.debug then
                    notifier.debug("Joining:")
                    notifier.debug("  1: "..sentences[n-1])
                    notifier.debug("  2: "..sentences[n])
                end

                -- Join these short sentences
                sentences[n-1] = sentences[n-1] .. " " .. sentences[n]
                table.remove(sentences, n)

                -- Update the word count that will be assigned to prev_words
                words = count_words(sentences[n-1])
                n = n - 1 -- we don't need n to increment since we joined the sentences
            end
        end

        prev_words = words
        n = n + 1
    end
    return sentences
end

local function split_paragraphs(text)

    if type(text) ~= "string" then
        return {}
    end

    -- Handle Windows line endings
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")

    local paragraphs = {}
    for section in (text .. "\n\n"):gmatch("(.-)\n\n") do
        if #section > 0 then
            table.insert(paragraphs, section)
        end
    end
    return paragraphs
end


local function get_default_quote_gender()
    local s, e = M.opts.voice:find([[^.f]])
    if s ~= nil then
        -- narrator is female, so use a male default
        return MALE
    end
    -- narrator is male, so use a male default
    return FEMALE
end

local function detect_gender(par)
    local female_patterns = {
        [[\bshe\b]],
        [[\bMrs\b]],
        [[\bMs\b]],
        [[\bwoman\b]],
    }
    local male_patterns = {
        [[\bhe\b]],
        [[\bMr\b]],
        [[\bman\b]],
    }

    local pos = 999
    local gender = get_default_quote_gender()

    for post_quote in par:gmatch([[".-"%s+([^.?!]+)]]) do

        for _, female_pattern in ipairs(female_patterns) do
            local s, _ = rex.find(post_quote, female_pattern)
            if s ~= nil then
                if debug then
                    notifier.debug("Detected FEMALE with: " ..female_pattern .. " in " .. post_quote)
                end
                if s < pos then
                    pos = s
                    gender = FEMALE
                end
            end
        end
        for _, male_pattern in ipairs(male_patterns) do
            local s, _ = rex.find(post_quote, male_pattern)
            if s ~= nil then
                if debug then
                    notifier.debug("Detected MALE with: " ..male_pattern .. " in " .. post_quote)
                end
                if s < pos then
                    pos = s
                    gender = MALE
                end
            end
        end
    end

    return gender
end

local function is_only_quote(par)
    local s, e = string.find(par, [[^"[^"]+"$]])
    if s ~= nil then
        return true
    end
    return false
end

local function split_quotes(par)
    local gender = detect_gender(par)

    if is_only_quote(par) then

        if debug then
            notifier.debug("Assume alternating gender")
        end

        -- Assume alternating gender
        local next_pos = #M.trans_gender_history + 1
        if next_pos > 2 then
            gender = M.trans_gender_history[next_pos - 2]
        end
    end

    table.insert(M.trans_gender_history, gender)


    local voice_blocks = {}
    local s, e, quote = string.find(par, [["(.-)"]])
    while s ~= nil do
        if s > 1 then
            table.insert(voice_blocks, {
                voice=M.opts.voice,
                text=par:sub(1, s-1),
            })
        end

        par = par:sub(e+1)

        if gender == MALE then
            table.insert(voice_blocks, {
                voice=M.opts.male_quote_voice,
                text=quote,
            })
        else
            table.insert(voice_blocks, {
                voice=M.opts.female_quote_voice,
                text=quote,
            })
        end

        s, e, quote = string.find(par, [["(.-)"]])
    end

    if par:find("%S") then
        table.insert(voice_blocks, {
            voice=M.opts.voice,
            text=par,
        })
    end

    return voice_blocks
end

function M.Kokoro(opts)
    local mode = vim.api.nvim_get_mode().mode
    notifier.trace("Mode: "..mode)
    notifier.trace("range: "..opts.range)
    notifier.trace("line1: "..opts.line1)
    notifier.trace("line2: "..opts.line2)

    local text = ""

    M.trans_gender_history = {} -- Reset gender history

    local paragraphs = {}

    -- Normal mode
    if opts.range == 0 then
        paragraphs = {
            vim.api.nvim_get_current_line()
        }
    end

    -- Visual mode
    if opts.range == 2 then
        paragraphs = split_paragraphs(get_selected_text())
    end

    notifier.debug("Paragraphs: ".. tostring(#paragraphs))

    local sections = {}
    for _, par in ipairs(paragraphs) do
        sections = split_quotes(par)
        for _, section in ipairs(sections) do
            notifier.trace("section_text: ".. section.text)
            local sentences = split_sentences(section.text)
            local sentance_groups = group_sentences(sentences)

            for _, text in ipairs(sentance_groups) do
                M.enqueue(M.create_clip(text, section.voice, M.opts.speed))
            end
        end
    end
end

function M.KokoroStop(opts)
    for i, clip in ipairs(M.clips) do
        if clip:is_rendering() then
            notifier.info("Stopping TTS for clip_id: "..clip.clip_id)
            vim.fn.jobstop(clip.tts_job_id)
        end
        M.clips[i].tts_code = 1
        M.clips[i].play_code = 1
    end

    -- Will only need to stop the fist clip
    if M.clips[1]:is_playing() then
        notifier.info("Stopping play for clip_id: "..M.clips[1].clip_id)
        vim.fn.jobstop(M.clips[1].play_job_id)
        M.clips = {M.clips[1]} -- remove other items in the queue
    else
        M.clips = {} -- remove other items in the queue
    end
end

-- Loads available voices
function M.LoadVoices()
    local cmd

    local voices = {}

    local job_opts = {
        cwd = M.opts.path,
        on_stdout = function(_, data)
            if data then
                vim.schedule(function()
                    for _, line in ipairs(data) do
                        local index_start, index_end, voice = string.find(line, "%s*%d*%.%s(.*)")
                        if index_start ~= nil then
                            notifier.debug("Found voice: "..voice)
                            table.insert(voices, voice)
                        end
                    end
                end)
            end
        end,
        on_stderr = function(_, data)
        end,
        on_exit = function(_, code)
            vim.schedule(function()
                if code == 0 then
                    notifier.info("Voices Loaded")
                    M.voices = voices
                else
                    notifier.error("Process exited with "..code..".  CMD: "..cmd)
                    if M.opts.debug then
                        notifier.debug("stdout: " .. table.concat(M.trans_stdout, "\n"))
                        notifier.debug("stderr: " .. table.concat(M.trans_stderr, "\n"))
                    end
                end

                M.tts()
            end)
        end,
    }

    local kokoro = M.opts.path.."/kokoro-tts"
    if M.opts.uv then
        kokoro = "uv run "..kokoro
    end

    cmd = string.format("%s --help-voices", kokoro)

    local job_id = vim.fn.jobstart(cmd, job_opts)
    if job_id <= 0 then
        notifier.error("Error: Failed to start command '" .. cmd .. "'")
        return
    end
end

function M.KokoroChooseVoice(opts)
    vim.ui.select(
        M.voices,
        {
            prompt = 'Select voice for Kokoro:',
            -- format_item = function(item)
                -- return "I'd like to choose " .. item
            -- end,
        },
        function(voice)
            M.opts.voice = voice
        end
    )
end



function M.KokoroChooseSpeed(opts)
    local speeds = {
        "0.5",
        "0.5",
        "0.7",
        "0.8",
        "0.9",
        "1.0",
        "1.1",
        "1.2",
        "1.3",
        "1.4",
        "1.5",
        "1.6",
        "1.7",
        "1.8",
        "1.9",
        "2.0",
    }

    vim.ui.select(
        speeds,
        {
            prompt = 'Select speed for Kokoro:',
            format_item = function(item)
                return item
            end,
        },
        function(speed)
            M.opts.speed = tonumber(speed)
        end
    )
end

---Set up configuration options for outline.
function M.setup(opts)
    -- local minor = vim.version().minor

    -- if minor < 7 then
    --   notifier.error('kokoro.nvim requires nvim-0.7 or higher!')
    -- return
    -- end

    M.opts = vim.tbl_deep_extend('force', M.opts, opts or {})

    notifier = libnotify.get_notifier(NOTIFICATION_TITLE, M.opts.notify_min_level)

    vim.fn.assert_notequal(nil, M.opts.path, "You must specify path to kokoro installation")

    if M.opts.load_voices then
        M.LoadVoices()
    end

    vim.api.nvim_create_user_command(
        'Kokoro',
        M.Kokoro,
        {
            range = true,
            desc = "Read text with Kokoro",
        }
    )

    vim.api.nvim_create_user_command('KokoroStop', M.KokoroStop, { desc = "Stop playing audio from Kokoro", })

    vim.api.nvim_create_user_command('KokoroChooseVoice', M.KokoroChooseVoice, { desc = "Select voice for Kokoro", })
    vim.api.nvim_create_user_command('KokoroChooseSpeed', M.KokoroChooseSpeed, { desc = "Select speed for Kokoro", })

end

return M
