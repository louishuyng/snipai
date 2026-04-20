local paths = require("snipai.claude.session_paths")

describe("snipai.claude.session_paths", function()
  describe("project_dir", function()
    it("maps absolute cwd to ~/.claude/projects/<dashed-cwd>", function()
      assert.equals(
        "/Users/x/.claude/projects/-Users-x-repo",
        paths.project_dir({ cwd = "/Users/x/repo", home = "/Users/x" })
      )
    end)

    it("preserves the leading slash as a leading dash", function()
      assert.equals(
        "/home/u/.claude/projects/-",
        paths.project_dir({ cwd = "/", home = "/home/u" })
      )
    end)

    it("rejects relative cwd", function()
      assert.has_error(function()
        paths.project_dir({ cwd = "repo", home = "/h" })
      end)
    end)

    it("rejects empty cwd", function()
      assert.has_error(function()
        paths.project_dir({ cwd = "", home = "/h" })
      end)
    end)

    it("falls back to $HOME when opts.home is nil", function()
      local saved = os.getenv("HOME")
      -- cannot actually mutate os env inside busted portably; just
      -- sanity-check the observed fallback path contains /.claude/projects/
      local got = paths.project_dir({ cwd = "/tmp/x" })
      assert.matches("/%.claude/projects/%-tmp%-x$", got)
      assert.is_truthy(saved) -- ensures HOME was set in CI
    end)
  end)

  describe("session_file", function()
    it("joins project_dir with <session_id>.jsonl", function()
      assert.equals(
        "/Users/x/.claude/projects/-Users-x-repo/027c08e4.jsonl",
        paths.session_file({
          cwd = "/Users/x/repo",
          home = "/Users/x",
          session_id = "027c08e4",
        })
      )
    end)

    it("rejects missing session_id", function()
      assert.has_error(function()
        paths.session_file({ cwd = "/x", home = "/h" })
      end)
      assert.has_error(function()
        paths.session_file({ cwd = "/x", home = "/h", session_id = "" })
      end)
    end)
  end)

  describe("_slug_of", function()
    it("replaces every slash with a dash", function()
      assert.equals("-a-b-c", paths._slug_of("/a/b/c"))
    end)
  end)
end)
