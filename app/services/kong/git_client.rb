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

    # R8.4: the config repo sits on the project's network too. A host this
    # machine cannot reach is told apart from one that refused the key or
    # token, and both from git failing for any other reason.
    class Unreachable < Error
      attr_reader :kind

      def initialize(message = nil, kind: :other)
        super(message)
        @kind = kind
      end
    end

    class AuthFailed < Error; end

    NETWORK_KINDS = %i[dns refused timeout tls].freeze

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

    # R8.4: what writing `relative_path` changed against the base, as a
    # unified diff -- a file that did not exist yet shows as all added.
    def diff(relative_path)
      run!("git", "add", "--intent-to-add", "--", relative_path, chdir: working_dir)
      run!("git", "diff", "--", relative_path, chdir: working_dir)
    end

    # The base branch's head on the remote, without touching a working copy
    # -- where a changeset began, and whether someone has pushed since.
    def remote_head_sha
      out = run!("git", "ls-remote", @repo, "refs/heads/#{@branch}", chdir: Dir.tmpdir)
      out.split.first.presence || raise(Error, "#{@branch} was not found in the config repo")
    end

    # R8.5: how many commits the pulled base branch has on top of `sha`, or
    # nil when `sha` is not in its history (rewritten, or never there).
    def commits_since(sha)
      run!("git", "cat-file", "-e", "#{sha}^{commit}", chdir: working_dir)
      run!("git", "rev-list", "--count", "#{sha}..HEAD", chdir: working_dir).strip.to_i
    rescue Error
      nil
    end

    # Back to a clean base branch: nothing a preview or a failed submit wrote
    # may linger into the next render.
    def discard!
      return self unless File.directory?(working_dir.join(".git"))

      run!("git", "reset", "--hard", chdir: working_dir)
      run!("git", "clean", "-fd", chdir: working_dir)
      run!("git", "checkout", @branch, chdir: working_dir)
      self
    end

    private

    def run!(*cmd, chdir:, env: {})
      stdout, stderr, status = Open3.capture3(env, *cmd, chdir: chdir.to_s)
      return stdout if status.success?

      output = stderr.presence || stdout
      message = "#{cmd.join(' ')} failed: #{output}"
      kind = Kong::NetworkFailure.classify_text(output)
      raise AuthFailed, message if kind == :auth
      raise Unreachable.new(message, kind: kind) if NETWORK_KINDS.include?(kind)

      raise Error, message
    end
  end
end
