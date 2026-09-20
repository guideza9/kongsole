require "open3"

module Kong
  # Shells out to the system `git` binary against a connection's decK config
  # repo (docs/DESIGN.md section 6, PR-mode step 2 and 5). Deliberately
  # host-agnostic -- no GitHub/GitLab/etc API calls -- since the git host is
  # still undecided (PRODUCT.md, "before M2"). Pushes a branch and stops;
  # opening an actual PR/MR against a host is a follow-up once one is chosen.
  #
  # Each connection gets its own shallow, cached working copy under
  # storage/git_cache/<connection_id> so repeated proposals don't reclone.
  class GitClient
    class Error < StandardError; end

    DEFAULT_BRANCH = "main"

    def initialize(connection:, working_dir: nil)
      @connection = connection
      @repo = connection.git_repo
      @branch = connection.git_branch.presence || DEFAULT_BRANCH
      @working_dir = working_dir
      raise Error, "connection #{connection.name} has no git_repo configured" if @repo.blank?
    end

    def working_dir
      @working_dir ||= Rails.root.join("storage", "git_cache", @connection.id.to_s)
    end

    # Clones the repo into working_dir if it isn't there yet, otherwise fetches
    # and hard-resets the base branch to origin -- so every proposal starts
    # from a clean, up-to-date base (docs/DESIGN.md's rule "ก": always build
    # YAML from git, never from a stale local copy).
    def pull!
      if File.directory?(working_dir.join(".git"))
        run!("git", "fetch", "origin", @branch, chdir: working_dir)
        run!("git", "checkout", @branch, chdir: working_dir)
        run!("git", "reset", "--hard", "origin/#{@branch}", chdir: working_dir)
      else
        FileUtils.mkdir_p(working_dir.dirname)
        run!("git", "clone", "--branch", @branch, @repo, working_dir.to_s, chdir: working_dir.dirname)
      end
      self
    end

    def checkout_branch!(name)
      run!("git", "checkout", "-B", name, chdir: working_dir)
      self
    end

    def write_file(relative_path, content)
      path = working_dir.join(relative_path)
      FileUtils.mkdir_p(path.dirname)
      File.write(path, content)
      self
    end

    def commit!(message, author_name: nil, author_email: nil)
      run!("git", "add", "-A", chdir: working_dir)
      env = {}
      if author_name.present?
        env["GIT_AUTHOR_NAME"] = env["GIT_COMMITTER_NAME"] = author_name
        env["GIT_AUTHOR_EMAIL"] = env["GIT_COMMITTER_EMAIL"] = author_email.presence || "#{author_name}@kong-integration.local"
      end
      run!("git", "commit", "-m", message, chdir: working_dir, env: env)
      commit_sha
    end

    def push!(branch)
      run!("git", "push", "origin", "#{branch}:#{branch}", chdir: working_dir)
      self
    end

    def commit_sha
      run!("git", "rev-parse", "HEAD", chdir: working_dir).strip
    end

    private

    def run!(*cmd, chdir:, env: {})
      stdout, stderr, status = Open3.capture3(env, *cmd, chdir: chdir.to_s)
      raise Error, "#{cmd.join(' ')} failed: #{stderr.presence || stdout}" unless status.success?

      stdout
    end
  end
end
