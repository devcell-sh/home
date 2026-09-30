# git.nix — git configuration and global ignores
# Imported by base.nix so all stacks get consistent git behavior.
# User name/email are set via container env vars (GIT_AUTHOR_NAME etc.),
# not here, so the image stays user-agnostic.
{...}: {
  programs.git = {
    enable = true;
    lfs.enable = true;

    settings = {
      init = {
        defaultBranch = "main";
        # libgit2 (used by Nix) doesn't support reftable yet
        defaultRefFormat = "files";
      };
      pull = {
        rebase = false;
        ff = true;
      };
      push = {
        autoSetupRemote = true;
      };
    };

    ignores = [
      "*~"
      ".DS_Store"
      ".idea/"
      ".scratch"
      ".secrets"
      "Makefile-ho"
      "hzl.mk"
      ".envrc"
      ".direnv"
      ".env"
      ".jira-config/"
      ".jira"
      ".claude"
      ".context"
      ".devcell"
      ".local"
      ".devcell.toml"
      "CLAUDE.md"
      ".worktrees"
      ".playwright-mcp"
      ".vagrant"
      ".tools"
      "core"
    ];
  };
}
