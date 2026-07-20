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
    TOTAL_SESSION_CAP = BEHAVIORAL_RUNS + TRIGGER_RUNS + MAX_JUDGE_RUNS
    SESSION_CAPS = {behavioral: BEHAVIORAL_RUNS, trigger: TRIGGER_RUNS, judge: MAX_JUDGE_RUNS}.freeze

    Lease = Struct.new(:id, :model, :reserved_cost, :timeout_seconds, :status,
                       :usage, :actual_cost, :reserved_at, :kind)

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
      if options.key?(:max_sessions) && options.fetch(:max_sessions) != TOTAL_SESSION_CAP
        raise Error, "session caps are fixed"
      end
      max_sessions = TOTAL_SESSION_CAP
      raise Error, "money limit must be positive" unless finite_numeric?(money_limit) && money_limit.to_f.finite? && money_limit > 0
      raise Error, "timeout must be positive" unless finite_numeric?(session_timeout_seconds) && session_timeout_seconds > 0
      raise Error, "max sessions must be positive" unless max_sessions.is_a?(Integer) && max_sessions > 0

      @money_limit = money_limit.to_f
      @prices = freeze_prices(prices || {})
      @session_timeout_seconds = session_timeout_seconds
      @max_sessions = max_sessions
      @spent = 0.0
      @reserved = 0.0
      @session_count = 0
      @session_counts = Hash.new(0)
      @reserved_time = 0
      @leases = {}
      @next_id = 0
      @lock = Mutex.new
    end

    def reserve_cost(model, usage)
      price = price_for(model)
      validate_usage(usage, price)
      cost = 0.0
      usage.each do |dimension, amount|
        rate = price.fetch(dimension.to_s) { raise Error, "price missing for #{dimension}" }
        raise Error, "price must be nonnegative" unless finite_numeric?(rate) && rate >= 0
        converted_rate = rate.to_f
        converted_amount = amount.to_f
        converted_cost = converted_rate * converted_amount
        unless finite_numeric?(converted_rate) && finite_numeric?(converted_amount) && finite_numeric?(converted_cost)
          raise Error, "cost is not finite"
        end
        cost += converted_cost
        raise Error, "cost is not finite" unless finite_numeric?(cost)
      end
      cost
    rescue KeyError
      raise Error, "price missing for #{model}"
    end

    def reserve!(model, pessimistic_usage, timeout_seconds = @session_timeout_seconds, kind: :behavioral)
      @lock.synchronize do
        raise Error, "unknown session kind" unless SESSION_CAPS.key?(kind)
        raise Error, "timeout must be positive" unless finite_numeric?(timeout_seconds) && timeout_seconds > 0
        raise Error, "session timeout exceeds operator time" if timeout_seconds > OPERATOR_TIME_SECONDS
        raise Error, "operator time ceiling exceeded" if @reserved_time + timeout_seconds > OPERATOR_TIME_SECONDS
        cost = reserve_cost(model, pessimistic_usage)
        raise Error, "session ceiling exceeded" if @session_counts[kind] >= SESSION_CAPS.fetch(kind)
        raise Error, "money ceiling exceeded" if @spent + @reserved + cost > @money_limit
        @next_id += 1
        lease = Lease.new("lease-#{@next_id}", model, cost, timeout_seconds, :reserved,
                          nil, nil, Time.now.to_i, kind)
        @leases[lease.id] = lease
        @reserved += cost
        @session_count += 1
        @session_counts[kind] += 1
        @reserved_time += timeout_seconds
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

    def remaining(kind = nil)
      @lock.synchronize do
        if kind
          raise Error, "unknown session kind" unless SESSION_CAPS.key?(kind)

          SESSION_CAPS.fetch(kind) - @session_counts[kind]
        else
          @max_sessions - @session_count
        end
      end
    end

    def remaining_time
      @lock.synchronize { OPERATOR_TIME_SECONDS - @reserved_time }
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

    def validate_usage(usage, price = nil)
      raise Error, "usage must be a nonempty numeric object" unless usage.is_a?(Hash) && !usage.empty?
      usage.each_value do |amount|
        unless finite_numeric?(amount) && amount >= 0
          raise Error, "usage must be a nonnegative numeric object"
        end
      end
      cap = price && (price["token_cap"] || price[:token_cap])
      if cap
        tokens = if usage.key?("total_tokens") || usage.key?(:total_tokens)
                   usage.key?("total_tokens") ? usage.fetch("total_tokens") : usage.fetch(:total_tokens)
                 else
                   input = usage.key?("input_tokens") ? usage.fetch("input_tokens") : usage.fetch(:input_tokens, nil)
                   output = usage.key?("output_tokens") ? usage.fetch("output_tokens") : usage.fetch(:output_tokens, nil)
                   if input || output
                     (input || 0) + (output || 0)
                   else
                     usage.fetch("input", usage.fetch(:input, 0)) +
                       usage.fetch("output", usage.fetch(:output, 0))
                   end
                 end
        raise Error, "token cap exceeded" if tokens > cap
      end
    end

    def fetch_lease(lease_id)
      @leases.fetch(lease_id) { raise Error, "unknown lease #{lease_id}" }
    end

    def finite_numeric?(value)
      value.is_a?(Numeric) && !value.is_a?(Complex) &&
        (!value.respond_to?(:finite?) || value.finite?)
    end

    def freeze_prices(prices)
      raise Error, "prices must be an object" unless prices.is_a?(Hash)
      copy = Marshal.load(Marshal.dump(prices))
      copy.each_value do |price|
        raise Error, "price must be an object" unless price.is_a?(Hash)
        price.each do |dimension, value|
          next if dimension.to_s == "token_cap"
          raise Error, "price must be nonnegative" unless finite_numeric?(value) && value >= 0
          raise Error, "price must be finite" unless finite_numeric?(value.to_f)
        end
        cap_entries = price.select { |dimension, _value| dimension.to_s == "token_cap" }
        cap_entries.each_value do |cap|
          unless finite_numeric?(cap) && cap.to_f.finite? && cap >= 0
            raise Error, "token cap must be finite and nonnegative"
          end
        end
      end
      deep_freeze(copy)
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, child| deep_freeze(key); deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end
    end
  end
end
