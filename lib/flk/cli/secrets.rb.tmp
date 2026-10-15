module Flk
  # flk secrets
  class CLI
    private

    def secrets_list(_args, o)
      rows = app.secrets.map { |k, v| { "name" => k, "digest" => Digest::SHA256.hexdigest(v)[0, 16] } }
      return puts(JSON.pretty_generate(rows)) if o[:json]
      return puts("No secrets") if rows.empty?
      Util.table(%w[NAME DIGEST], rows.map(&:values))
    end

    def secrets_set(args, o)
      update_secrets(o) do |s|
        args.each do |kv|
          k, v = kv.split("=", 2)
          raise Error, "bad secret '#{kv}' (want KEY=VALUE)" if v.nil?
          raise Error, "invalid secret name '#{k}'" unless k.match?(ENV_KEY)
          s[k] = v == "-" ? $stdin.read.chomp : v
        end
      end
    end

    def secrets_import(_args, o)
      update_secrets(o) do |s|
        $stdin.each_line do |l|
          next if l.strip.empty? || l.start_with?("#")
          k, v = l.chomp.split("=", 2)
          raise Error, "bad line: #{l.strip}" unless v && k.match?(ENV_KEY)
          s[k] = v
        end
      end
    end

    def secrets_unset(args, o)
      update_secrets(o) { |s| args.each { |k| s.delete(k) or warn "no secret #{k}" } }
    end

    def update_secrets(o)
      a = app
      s = a.secrets
      yield s
      a.save_secrets(s)
      puts "Secrets updated"
      if o[:stage]
        puts "Staged; applies on next start/deploy"
        return next_step("flk deploy", "flk machine restart ID")
      end
      a.machines.select(&:running?).each do |m|
        VM.stop(m)
        boot(m, "Machine #{m.id} [#{m.name}] restarted with new secrets")
      end
    end
  end
end
