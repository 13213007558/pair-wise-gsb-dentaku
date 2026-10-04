module Dentaku
  class GradientResult
    STATUSES = %i[ok non_differentiable unknown_derivative custom_function_error evaluation_error].freeze

    attr_reader :result, :gradient, :status, :reasons

    def initialize(result: nil, gradient: {}, status: :ok, reasons: [])
      @result = result
      @gradient = gradient
      @status = status
      @reasons = reasons
    end

    def ok?
      status == :ok
    end

    def success?
      ok?
    end

    def to_h
      {
        result: result,
        gradient: gradient,
        status: status,
        reasons: reasons
      }
    end
    alias_method :to_hash, :to_h

    def deconstruct_keys(keys)
      keys ? to_h.slice(*keys) : to_h
    end
  end

  class GradientError < BaseError
    attr_reader :gradient_result

    def initialize(gradient_result)
      @gradient_result = gradient_result
      message = gradient_result.reasons.map(&:message).join('; ')
      message = gradient_result.status.to_s.tr('_', ' ') if message.empty?
      super(message)
    end
  end
end
