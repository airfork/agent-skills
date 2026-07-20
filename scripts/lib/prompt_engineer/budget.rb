require "thread"

module PromptEngineer
  module Budget
    BEHAVIORAL_RUNS = 96
    INITIAL_BEHAVIORAL_RUNS = 72
    STABILITY_BEHAVIORAL_RUNS = 18
    TARGETED_BEHAVIORAL_RUNS = 6
    TRIGGER_RUNS = 40
    EXPLICIT_TRIGGER_RUNS = 16
    CODEX_IMPLICIT_TRIGGER_RUNS = 16
    CLAUDE_NEGATIVE_TRIGGER_RUNS = 8
    MAX_JUDGE_RUNS = 64
    INITIAL_JUDGE_RUNS = 32
    CONDITIONAL_JUDGE_RUNS = 32
    OPERATOR_TIME_SECONDS = 8 * 60 * 60

    Lease = Struct.new(:id, :model, :reserved_cost, :timeout_seconds, :status,
                       :usage, :actual_cost, :reserved_at)

    class Error < StandardError; end

    attr_reader :money_limit, :session_timeout_seconds, :max_sessions, :spent

    def self.new(**options)
      Ledger.new(options)
    end

    class Ledger
      attr_reader :money_limit, :session_timeout_seconds, :max_sessions, :spent

    def initialize(options)
      money_limit = options.fetch(:money_limit)
      prices = options.fetch(:prices)
      session_timeout_seconds = options.fetch(:session_timeout_seconds, 8 * 60 * 60)
      max_sessions = options.fetch(:max_sessions, BEHAVIORAL_RUNS + TRIGGER_RUNS + MAX_JUDGE_RUNS)
      raise Error, "money limit must be positive" unless money_limit.is_a?(Numeric) && money_limit > 0
      raise Error, "timeout must be positive" unless session_timeout_seconds.is_a?(Numeric) && session_timeout_seconds > 0
      raise Error, "max sessions must be positive" unless max_sessions.is_a?(Integer) && max_sessions > 0

      @money_limit = money_limit.to_f
      @prices = prices || {}
      @session_timeout_seconds = session_timeout_seconds
      @max_sessions = max_sessions
      @spent = 0.0
      @reserved = 0.0
      @session_count = 0
      @leases = {}
      @next_id = 0
      @lock = Mutex.new
    end

    def reserve_cost(model, usage)
      price = price_for(model)
      validate_usage(usage)
      cost = 0.0
      usage.each do |dimension, amount|
        rate = price.fetch(dimension.to_s) { raise Error, "price missing for #{dimension}" }
        cost += rate.to_f * amount.to_f
      end
      cost
    rescue KeyError
      raise Error, "price missing for #{model}"
    end

    def reserve!(model, pessimistic_usage, timeout_seconds = @session_timeout_seconds)
      @lock.synchronize do
        raise Error, "session timeout exceeds operator time" if timeout_seconds > OPERATOR_TIME_SECONDS
        cost = reserve_cost(model, pessimistic_usage)
        raise Error, "session ceiling exceeded" if @session_count >= @max_sessions
        raise Error, "money ceiling exceeded" if @spent + @reserved + cost > @money_limit
        @next_id += 1
        lease = Lease.new("lease-#{@next_id}", model, cost, timeout_seconds, :reserved,
                          nil, nil, Time.now.to_i)
        @leases[lease.id] = lease
        @reserved += cost
        @session_count += 1
        lease
      end
    end

    def settle!(lease_id, usage)
      @lock.synchronize do
        lease = fetch_lease(lease_id)
        raise Error, "native usage is required" unless usage.is_a?(Hash)
        raise Error, "lease is not reservable" unless lease.status == :reserved
        actual = reserve_cost(lease.model, usage)
        raise Error, "settled cost exceeds reservation" if actual > lease.reserved_cost
        lease.usage = usage
        lease.actual_cost = actual
        lease.status = :settled
        @reserved -= lease.reserved_cost
        @spent += actual
        lease
      end
    end

    def expire!(lease_id)
      @lock.synchronize do
        lease = fetch_lease(lease_id)
        raise Error, "lease is not reservable" unless lease.status == :reserved
        lease.status = :expired
        lease
      end
    end

    def crash!(lease_id)
      @lock.synchronize do
        lease = fetch_lease(lease_id)
        raise Error, "lease is not reservable" unless lease.status == :reserved
        lease.status = :crashed
        lease
      end
    end

    def close!(lease_id, evidence)
      @lock.synchronize do
        lease = fetch_lease(lease_id)
        raise Error, "closure evidence is required" if evidence.nil? || evidence.to_s.empty?
        unless %i[expired crashed].include?(lease.status)
          raise Error, "only expired or crashed leases can be closed"
        end
        lease.status = :closed
        @reserved -= lease.reserved_cost
        @spent += lease.reserved_cost
        lease
      end
    end

    def lease(lease_id)
      @lock.synchronize { fetch_lease(lease_id) }
    end

    def remaining_sessions
      @lock.synchronize { @max_sessions - @session_count }
    end

    def remaining_money
      @lock.synchronize { @money_limit - @spent - @reserved }
    end

    def leases
      @lock.synchronize { @leases.values.dup }
    end

    private

    def price_for(model)
      price = @prices[model] || @prices[model.to_s]
      raise Error, "unknown price #{model}" unless price.is_a?(Hash)

      price
    end

    def validate_usage(usage)
      raise Error, "usage must be a nonnegative numeric object" unless usage.is_a?(Hash)
      usage.each_value do |amount|
        unless amount.is_a?(Numeric) && amount >= 0
          raise Error, "usage must be a nonnegative numeric object"
        end
      end
    end

    def fetch_lease(lease_id)
      @leases.fetch(lease_id) { raise Error, "unknown lease #{lease_id}" }
    end
    end
  end
end
