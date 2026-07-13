# File-based coordinator lease with fencing tokens for milestone-orchestrator.
# One live coordinator per run: acquisition is exclusive, takeover requires
# expiry, and every mutation revalidates owner + fencing token. Dependency-free;
# targets Ruby 2.6.
require "json"
require "fileutils"

module MilestoneOrchestrator
  class LeaseStore
    class LeaseError < StandardError; end
    class StaleLease < LeaseError; end
    class HeldByOther < LeaseError; end

    def initialize(dir)
      @dir = dir
      @lease_path = File.join(dir, "lease.json")
      @lock_path = File.join(dir, "lease.lock")
      FileUtils.mkdir_p(dir)
    end

    # Grants, renews (same owner, live), or takes over (expired) the lease.
    # Raises HeldByOther when a different owner holds a live lease.
    def acquire(owner, ttl_seconds)
      with_lock do
        now = Time.now
        current = read_lease
        if current && live?(current, now) && current["owner"] != owner
          raise HeldByOther, "lease held by #{current["owner"].inspect} until #{current["expires_at"]}"
        end
        lease =
          if current && live?(current, now) && current["owner"] == owner
            current.merge(
              "renewed_at" => now.utc.iso8601,
              "expires_at" => (now + ttl_seconds).utc.iso8601,
              "ttl_seconds" => ttl_seconds
            )
          else
            {
              "owner" => owner,
              "epoch" => current ? current.fetch("epoch") + 1 : 1,
              "fencing_token" => current ? current.fetch("fencing_token") + 1 : 1,
              "renewed_at" => now.utc.iso8601,
              "expires_at" => (now + ttl_seconds).utc.iso8601,
              "ttl_seconds" => ttl_seconds
            }
          end
        write_lease(lease)
        lease
      end
    end

    # Raises StaleLease unless owner holds the live lease with this token.
    def validate!(owner, fencing_token)
      with_lock do
        current = read_lease
        unless current && live?(current, Time.now)
          raise StaleLease, "no live lease; acquire-lease first"
        end
        unless current["owner"] == owner && current["fencing_token"] == fencing_token
          raise StaleLease,
                "stale lease credentials for #{owner.inspect} (token #{fencing_token}); " \
                "current owner #{current["owner"].inspect} token #{current["fencing_token"]}"
        end
        current
      end
    end

    def renew(owner, fencing_token)
      current = validate!(owner, fencing_token)
      acquire(owner, current.fetch("ttl_seconds", 300))
    end

    def release(owner, fencing_token)
      validate!(owner, fencing_token)
      with_lock { File.delete(@lease_path) if File.exist?(@lease_path) }
    end

    private

    def live?(lease, now)
      Time.parse(lease.fetch("expires_at")) > now
    rescue ArgumentError
      false
    end

    def read_lease
      return nil unless File.exist?(@lease_path)
      JSON.parse(File.read(@lease_path))
    rescue JSON::ParserError
      nil
    end

    def write_lease(lease)
      tmp = "#{@lease_path}.tmp"
      File.write(tmp, JSON.pretty_generate(lease))
      File.rename(tmp, @lease_path)
    end

    def with_lock
      File.open(@lock_path, File::RDWR | File::CREAT) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end
  end
end

require "time"
