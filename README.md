This plugin can can help people check text by listening to Kokoro read it.
* Breaks paragraphs into sentances and renders *two* at a time asynchronously.  Audio typically has a 1-2 second start delay, but is smooth after that.

While playing with it, I made it so that it can read books ok too.
* Quoted text will be read in another voice.
* Detects the gender of the speaker and use the appropriate gendered voice.
* Tracks gender used in paragraphs so that paragraphs with quoted text only will use the gender from two paragraphs below to support common back and forth dialog.


# Demonstration

A demonstration can be found at <https://cskeeters.github.io/kokoro.nvim/>.

# Installation

This plugin requires the luarock `lrexlib-pcre`. Use `--lua-version=5.1` to install for neovim.

```sh
luarocks install lrexlib-pcre --lua-version=5.1
```

To install with [lazy.nvim](https://github.com/folke/lazy.nvim), You need something like this:

```lua
{
    'cskeeters/kokoro.nvim',
    lazy = false,
    config = function()
        -- Verify installation of lrexlib-pcre
        local ok, rex = pcall(require, "rex_pcre")
        if not ok then
            print("Failed to load lrexlib-pcre: " .. rex)
            print("Install with:")
            print("  luarocks install lrexlib-pcre --lua-version=5.1")
        end

        require 'kokoro'.setup({
            -- Setting debug to true will route tinymist's stderr to :messages
            debug = false,
            path = os.getenv("HOME")..'/working/kokoro-tts',
            player = "afplay",

            conda_env = "kokoro",

            load_voices = true,

            voice = "af_aoede",
        })

        -- NOTE: <Cmd> will prevent range from passing into the function correctly
        vim.keymap.set({'v'}, '<Leader>gk', ":Kokoro<Cr>", { noremap=true, silent=true, desc="Read selected text with Kokoro" })
        vim.keymap.set({'n'}, '<Leader>gk', ":Kokoro<Cr>", { noremap=true, silent=true, desc="Read current line with Kokoro" })
        vim.keymap.set({'n'}, '<Leader>gK', ":KokoroStop<Cr>", { noremap=true, silent=true, desc="Stop playing audio from Kokoro" })
        vim.keymap.set({'n'}, '<Leader><Leader>gkv', ":KokoroChooseVoice<Cr>", { noremap=true, silent=true, desc="Choose voice for Kokoro" })
        vim.keymap.set({'n'}, '<Leader><Leader>gks', ":KokoroChooseSpeed<Cr>", { noremap=true, silent=true, desc="Choose speed for Kokoro" })
    end
}
```

## Setup Options

```lua
{
  -- Kokoro Runtime
  path = nil,
  conda_env = nil,
  player = "afplay",

  -- Plugin Options
  debug = false,
  workers = 2,
  load_voices = true,
  word_threshold = 15,

  -- Kokoro options
  voice = "af_aoede",
  speed = 1.0,
  male_quote_voice="bm_lewis",
  female_quote_voice="bf_alice",
}
```

# Commands

| Command              | Mode | Action                          |
|----------------------|------|---------------------------------|
| `:Kokoro`            | n    | Reads the line under the cursor |
| `:Kokoro`            | v/V  | Reads the selected text.        |
| `:KokoroStop`        | n    | Stops reading immediately       |
| `:KokoroChooseVoice` | n    | Choose a voice                  |
| `:KokoroChooseSpeed` | n    | Choose a reading speed          |
