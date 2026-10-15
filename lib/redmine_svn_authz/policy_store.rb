# frozen_string_literal: true

module RedmineSvnAuthz
  # Loads and caches parsed policies per SvnAuthzConfig. Entries are keyed by
  # a fingerprint (file mtime/size or content digest), so edits to the authz
  # file or the managed rules are picked up without restarting Redmine.
  module PolicyStore
    Entry = Struct.new(:fingerprint, :policy)

    @cache = {}
    @mutex = Mutex.new

    class << self
      # Returns the Policy for +config+, or nil if the rules cannot be loaded
      # (missing file, syntax errors). Callers must treat nil as "deny all".
      def policy_for(config)
        fingerprint = fingerprint_for(config)
        return nil unless fingerprint

        cached = @mutex.synchronize { @cache[config.id] }
        return cached.policy if cached && cached.fingerprint == fingerprint

        policy = Parser.parse(config.authz_text)
        unless policy.valid?
          Rails.logger.error "[svn_authz] invalid authz rules for repository ##{config.repository_id}: " +
                             policy.errors.map(&:to_s).join('; ')
          policy = nil
        end
        @mutex.synchronize { @cache[config.id] = Entry.new(fingerprint, policy) }
        policy
      end

      def fingerprint_for(config)
        if config.file_source?
          stat = File.stat(config.authz_file_path)
          "file:#{config.authz_file_path}:#{stat.mtime.to_f}:#{stat.size}"
        else
          "db:#{Digest::SHA256.hexdigest(config.authz_content.to_s)}"
        end
      rescue SystemCallError => e
        Rails.logger.error "[svn_authz] cannot read #{config.authz_file_path}: #{e.message}"
        nil
      end

      def clear
        @mutex.synchronize { @cache.clear }
      end
    end
  end
end
