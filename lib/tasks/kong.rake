namespace :kong do
  desc "Upsert KongConnection registry rows from config/connections.yml"
  task load_connections: :environment do
    connections = Kong::ConnectionsConfigLoader.call
    connections.each { |c| puts "#{c.persisted? ? 'ok' : 'FAILED'}  #{c.name} (#{c.env}, rank #{c.rank})" }
    puts "#{connections.size} connection(s) loaded from #{Kong::ConnectionsConfigLoader::DEFAULT_PATH}"
  end

  desc "Seed a local bare decK config repo for the uat connection (M2, local dev only -- no real git host yet)"
  task seed_config_repo: :environment do
    require "open3"
    require "fileutils"
    require "tmpdir"

    bare_repo = Rails.root.join("storage", "config_repos", "uat.git")
    if File.directory?(bare_repo)
      puts "#{bare_repo} already exists -- nothing to do"
      next
    end

    FileUtils.mkdir_p(bare_repo.dirname)
    run!("git", "init", "--bare", "--initial-branch=main", bare_repo.to_s)

    Dir.mktmpdir do |scratch|
      run!("git", "clone", bare_repo.to_s, scratch)
      skeleton = Kong::DeckRenderer.serialize(Kong::DeckRenderer.parse(nil, select_tags: [ "managed-by-kongctl" ]))
      FileUtils.mkdir_p(File.join(scratch, "uat"))
      File.write(File.join(scratch, "uat", "kong.yaml"), skeleton)
      run!("git", "add", "-A", chdir: scratch)
      run!("git", "-c", "user.name=kongctl", "-c", "user.email=kongctl@kong-integration.local",
        "commit", "-m", "Seed empty decK config", chdir: scratch)
      run!("git", "push", "origin", "main", chdir: scratch)
    end

    puts "Seeded #{bare_repo}"
  end

  def run!(*cmd, chdir: nil)
    stdout, stderr, status = Open3.capture3(*cmd, chdir: chdir || Dir.pwd)
    raise "#{cmd.join(' ')} failed: #{stderr.presence || stdout}" unless status.success?

    stdout
  end
end
