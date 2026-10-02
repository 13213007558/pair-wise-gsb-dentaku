require 'fiber'
require_relative 'exceptions'

require_relative 'flat_hash'

module Dentaku
  class CalculationSession
    SESSION_KEY = :__dentaku_calculation_session

    attr_reader :error, :expression, :required_variables

    def self.start!(calculator, expression, data = {})
      session = new(calculator, expression, data)
      session.resume!
      session
    end

    def self.failed(calculator, expression, error)
      allocate.tap do |session|
        session.send(:initialize_failed, calculator, expression, error)
      end
    end

    def initialize(calculator, expression, data = {})
      @calculator = calculator
      @expression = expression
      @context = isolated(calculator.memory)
      @required_variables = []
      @status = :pending

      store_values(data)
      @context[SESSION_KEY] = self
      @node = calculator.ast(expression)
      @fiber = Fiber.new do
        @result = @node.value(session_context)
        @status = :complete
        @result
      end
    end

    def resume!(values = {})
      ensure_resumable!
      store_values(values)

      outcome = @fiber.resume

      if @fiber.alive?
        @required_variables = [outcome].compact
      else
        @status = :complete
        @required_variables = []
        @result = outcome
      end

      self
    rescue StandardError => error
      @status = :failed
      @error = error
      @required_variables = []
      raise
    end
    alias_method :continue!, :resume!
    alias_method :provide!, :resume!

    def resume(values = {})
      resume!(values)
    rescue StandardError
      self
    end
    alias_method :continue, :resume
    alias_method :provide, :resume

    def pending?
      status == :pending
    end

    def complete?
      status == :complete
    end

    def failed?
      status == :failed
    end

    def result
      raise SessionStateError, 'calculation session has not completed' unless complete?

      @result
    end
    alias_method :value, :result

    def status
      @status
    end

    def probe(node, context)
      fiber = Fiber.new { node.value(context) }
      outcome = fiber.resume
      [fiber, outcome]
    end

    def await_probe(fiber, outcome)
      while fiber.alive?
        Fiber.yield(outcome)
        outcome = fiber.resume
      end

      outcome
    end

    def try_probe(node, context)
      probe(node, context)
    rescue StandardError
      nil
    end

    private def initialize_failed(calculator, expression, error)
      @calculator = calculator
      @expression = expression
      @context = isolated(calculator.memory)
      @required_variables = []
      @status = :failed
      @error = error
      @fiber = nil
    end

    private

    def ensure_resumable!
      return if pending?

      state = failed? ? 'failed' : 'completed'
      raise SessionStateError, "cannot resume a #{state} calculation session"
    end

    def session_context
      @context
    end

    def store_values(values)
      pairs = @calculator.nested_data_support ? FlatHash.from_hash_with_intermediates(values) : values
      pairs.each do |key, value|
        standardized_key = @calculator.send(:standardize_case, key.to_s)
        next if standardized_key == SESSION_KEY.to_s

        @context[standardized_key] = isolated(value)
      end
    end

    def isolated(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), result| result[key] = isolated(item) }
      when Array
        value.map { |item| isolated(item) }
      else
        value
      end
    end
  end

  class SessionStateError < BaseError; end

  Session = CalculationSession
end
