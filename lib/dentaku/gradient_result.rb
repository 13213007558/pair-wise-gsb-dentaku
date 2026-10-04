module Dentaku
  class GradientResult
    STATUSES = %i[ok non_differentiable unknown_derivative function_error].freeze

    attr_reader :value, :gradient, :status, :error

    def initialize(value: nil, gradient: {}, status: :ok, error: nil)
      @value = value
      @gradient = gradient
      @status = status
      @error = error
    end

    def ok?
      status == :ok
    end

    def to_h
      { value: value, gradient: gradient, status: status, error: error }
    end
    alias_method :to_hash, :to_h

  end
end
