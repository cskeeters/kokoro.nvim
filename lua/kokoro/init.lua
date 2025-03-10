-- local utils = require('outline.utils.init')

local FEMALE=0
local MALE=1

local function write_to_file(filename, text)
  -- Open file in write mode ("w" overwrites, "a" appends)
  local file, err = io.open(filename, "w")
  if not file then
    print("Error opening file: " .. (err or "unknown error"))
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
  current = nil,
  trans_text = {}, -- queue of text to convert to audio

  trans_job_id = 0,
  trans_stdout = {},
  trans_stderr = {},

  trans_txt_temp = "",
  trans_txt_trunc = "",
  trans_wav_temp = "",
  trans_gender_history = {}, -- This is not what it looks like

  play_files = {}, -- queue of {wav_path,text) to play

  play_trunc = "", -- Text that is currently playing

  play_job_id = 0,
  play_stdout = {},
  play_stderr = {},

  voices = {}, -- Voices available for selection (kokoro-tts --help-voices)

  opts = {
    -- Kokoro Runtime
    path = nil,
    conda_env = nil,
    player = "afplay",

    -- Plugin Options
    debug = false,
    load_voices = true,
    word_threshold = 15,


    -- Kokoro options
    voice = "af_nicole",
    speed = 1.0,
    male_quote_voice="bm_lewis",
    female_quote_voice="bf_alice",
  },

}


function M.play_next()
  local cmd

  local job_opts = {
    stdin = 'pipe',  -- Enable stdin as a pipe
    on_stdout = function(_, data)
      if data then
        vim.schedule(function()
          for _, line in ipairs(data) do
            table.insert(M.play_stdout, line)
          end
        end)
      end
    end,
    on_stderr = function(_, data)
      if data then
        vim.schedule(function()
          for _,line in ipairs(data) do
            table.insert(M.play_stderr, line)
          end
        end)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        M.play_job_id = 0

        if code ~= 0 then
          vim.notify("Process exited with "..code..".  CMD: "..cmd, vim.log.levels.ERROR)
          if M.opts.debug then
            vim.notify("stdout: " .. table.concat(M.trans_stdout, "\n"), vim.log.levels.DEBUG)
            vim.notify("stderr: " .. table.concat(M.trans_stderr, "\n"), vim.log.levels.DEBUG)
          end
        else
          vim.notify("Finished Playing: "..M.play_trunc, vim.log.levels.INFO)
        end

        M.play_next()
      end)
    end,
    -- stdout_buffered = true,
    -- stderr_buffered = true,
  }
  if M.play_job_id <= 0 then
    if #M.play_files > 0 then
      local wav_file
      wav_file, M.play_trunc = unpack(table.remove(M.play_files, 1))
      vim.notify("Playing: "..M.play_trunc, vim.log.levels.INFO)
      cmd = string.format([[%s "%s"]], M.opts.player, wav_file)
      M.play_job_id = vim.fn.jobstart(cmd, job_opts)
      if M.play_job_id <= 0 then
        print("Error: Failed to start command '" .. cmd .. "'")
        return
      end
    end
  end
end

-- See if we can play the next clip
function M.trans_next()
  local cmd
  local job_opts = {
    stdin = 'pipe',  -- Enable stdin as a pipe
    cwd = M.opts.path,
    on_stdout = function(_, data)
      if data then
        vim.schedule(function()
          for _, line in ipairs(data) do
            table.insert(M.trans_stdout, line)
          end
        end)
      end
    end,
    on_stderr = function(_, data)
      if data then
        vim.schedule(function()
          for _, line in ipairs(data) do
            table.insert(M.trans_stderr, line)
          end
        end)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        M.trans_job_id = 0

        if code == 0 then
          table.insert(M.play_files,{M.trans_wav_temp, M.trans_txt_trunc})
          vim.notify(string.format("Finished Translating: %s", M.trans_txt_trunc), vim.log.levels.INFO)

          M.play_next()
        else
          vim.notify("Process exited with "..code..".  CMD: "..cmd, vim.log.levels.ERROR)
          if M.opts.debug then
            vim.notify("stdout: " .. table.concat(M.trans_stdout, "\n"), vim.log.levels.DEBUG)
            vim.notify("stderr: " .. table.concat(M.trans_stderr, "\n"), vim.log.levels.DEBUG)
          end
        end

        M.trans_next()
      end)
    end,
    -- stdout_buffered = true,
    -- stderr_buffered = true,
  }


  if M.trans_job_id <= 0 then -- Are we currently running a job?

    if #M.trans_text > 0 then -- do we have more text to convert to audio?

      M.trans_txt_temp = vim.fn.tempname()

      local section = table.remove(M.trans_text,1)
      if not write_to_file(M.trans_txt_temp, section.text) then
        print("Error writing to text tmp file for kokoro")
        return
      end

      local kokoro = M.opts.path.."/kokoro-tts"
      if M.opts.conda_env ~= nil then
        kokoro = "conda run -n "..M.opts.conda_env.." "..kokoro
      end

      M.trans_wav_temp = vim.fn.tempname()..".wav"
      M.trans_txt_trunc = truncate_string(section.text, 50)

      cmd = string.format("%s %s %s --speed %f --voice %s", kokoro, M.trans_txt_temp, M.trans_wav_temp, M.opts.speed, section.voice)
      vim.notify(string.format("Translating text: %s", M.trans_txt_trunc), vim.log.levels.INFO)
      M.trans_job_id = vim.fn.jobstart(cmd, job_opts)
      if M.trans_job_id <= 0 then
        print("Error: Failed to start command '" .. cmd .. "'")
        return
      end
    end
  end
end

function M.enqueue(voice, text)
  table.insert(M.trans_text,{voice=voice, text=text})
  M.trans_next()
end

local function get_selected_text()
  -- getpos returns [bufnum, lnum, col, off]
  -- lnum and col are 1 based
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  -- print("start_pos: "..vim.inspect(start_pos))
  -- print("end_pos: "..vim.inspect(end_pos))

  local start_line = start_pos[2]
  local start_col = start_pos[3]

  local end_line = end_pos[2]
  local end_col = end_pos[3]


  -- print("start_line: "..start_line)
  -- print("end_line: "..end_line)

  local selected_text = {}
  -- nvim_buf_get_lines start and end lines are 0 based
  local lines = vim.api.nvim_buf_get_lines(0, start_line-1, end_line, false)
  for no = start_line,end_line do
    local line = lines[no - start_line + 1]
    -- print("Line: "..line)
    if no == start_line then
      if no == end_line then
        -- print("no: "..no)
        -- print("start_line: "..start_line)
        -- print("start_col: "..start_col)
        -- print("end_col: "..end_col)
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

local function split_sentences_orig(text)
  local sentences = {}

  local s,e = string.find(text, "[%.!?]%s")
  while s ~= nil do
    table.insert(sentences, text:sub(1, s+1))
    text = text:sub(e)
    s,e = string.find(text, "[%.!?]%s")
  end

  table.insert(sentences, text)

  return sentences
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
      print("words: "..words .. " prev_words: "..prev_words)
    end

    if prev_words < M.opts.word_threshold then
      if words < M.opts.word_threshold then

        if M.opts.debug then
          print("Joining:")
          print("  1: "..sentences[n-1])
          print("  2: "..sentences[n])
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
    [[%W*she%W*]],
    [[%W*Mrs%W*]],
    [[%W*Ms%W*]],
    [[%W*woman%W*]],
  }
  local male_patterns = {
    [[%W*he%W*]],
    [[%W*Mr%W*]],
    [[%W*man%W*]],
  }

  local pos = 999
  local gender = get_default_quote_gender()

  for post_quote in par:gmatch([[".-"%s+([^.?!]+)]]) do
    print("post_quote: " ..post_quote)

    local s, e
    for _, female_pattern in ipairs(female_patterns) do
      s, e = post_quote:find(female_pattern)
      if s ~= nil then
        print("Detected FEMALE with: " ..female_pattern .. " " .. tostring(s))
        if s < pos then
          print("...setting")
          pos = s
          gender = FEMALE
        end
      end
    end
    for _, male_pattern in ipairs(male_patterns) do
      s, e = post_quote:find(male_pattern)
      if s ~= nil then
        print("Detected MALE with: " ..male_pattern .. " " .. tostring(s))
        if s < pos then
          print("...setting")
          pos = s
          gender = MALE
        end
      end
    end
  end

  return gender
end

local function detect_character(par)
  return nil
end

local function is_only_quote(par)
  local s, e = string.find(par, [[^"[^"]+"$]])
  if s ~= nil then
    print("is_only_quote")
    return true
  end
  print("is_only_quote nope: "..par)
  return false
end

local function split_quotes(par)
  local gender = detect_gender(par)

  if is_only_quote(par) then

    if debug then print("Assume alternating gender") end

    -- Assume alternating gender
    local next_pos = #M.trans_gender_history + 1
    if next_pos > 2 then
      gender = M.trans_gender_history[next_pos - 2]
    end
  end

  table.insert(M.trans_gender_history, gender)


  -- local character = detect_character(par)

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
  -- print("Mode: "..mode)
  -- print("range: "..opts.range)
  -- print("line1: "..opts.line1)
  -- print("line2: "..opts.line2)

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

  print("Paragraphs: ".. tostring(#paragraphs))

  local sections = {}
  for _, par in ipairs(paragraphs) do
    sections = split_quotes(par)
    for _, section in ipairs(sections) do
      print("section_text: ".. section.text)
      local sentences = split_sentences(section.text)
      local sentance_groups = group_sentences(sentences)

      for _, text in ipairs(sentance_groups) do
        M.enqueue(section.voice, text)
      end
    end
  end
end

function M.KokoroStop(opts)
  M.trans_text = {} -- clear translation queue
  if M.trans_job_id > 0 then
    vim.fn.jobstop(M.trans_job_id)
  end

  M.play_files = {} -- clear play queue
  if M.play_job_id > 0 then
    vim.fn.jobstop(M.play_job_id)
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
              print("Found voice: "..voice)
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
          vim.notify("Voices Loaded", vim.log.levels.INFO)
          M.voices = voices
        else
          vim.notify("Process exited with "..code..".  CMD: "..cmd, vim.log.levels.ERROR)
          if M.opts.debug then
            vim.notify("stdout: " .. table.concat(M.trans_stdout, "\n"), vim.log.levels.DEBUG)
            vim.notify("stderr: " .. table.concat(M.trans_stderr, "\n"), vim.log.levels.DEBUG)
          end
        end

        M.trans_next()
      end)
    end,
  }

  local kokoro = M.opts.path.."/kokoro-tts"
  if M.opts.conda_env ~= nil then
    kokoro = "conda run -n "..M.opts.conda_env.." "..kokoro
  end

  cmd = string.format("%s --help-voices", kokoro)

  local job_id = vim.fn.jobstart(cmd, job_opts)
  if job_id <= 0 then
    print("Error: Failed to start command '" .. cmd .. "'")
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
  -- vim.notify('kokoro.nvim requires nvim-0.7 or higher!', vim.log.levels.ERROR)
  -- return
  -- end


  M.opts = vim.tbl_deep_extend('force', M.opts, opts or {})

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
