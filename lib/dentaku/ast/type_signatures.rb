require_relative '../type_signature'

module Dentaku
  module TypeSignatures
    NUMERIC_VARIADIC = [{ params: [{ variadic: [:numeric, { array: :numeric }] }], return: :numeric }].freeze
    LOGICAL_VARIADIC = [{ params: [{ variadic: [:logical, :nil] }], return: :logical }].freeze

    class << self
      def register!
        registry = AST::Function.registry
        registry.register_signatures(:abs, [{ params: [:numeric], return: :numeric }])
        registry.register_signatures(:round, [
          { params: [:numeric], return: :numeric },
          { params: %i[numeric numeric], return: :numeric }
        ])
        registry.register_signatures(:roundup, [{ params: %i[numeric numeric], return: :numeric }])
        registry.register_signatures(:rounddown, [{ params: %i[numeric numeric], return: :numeric }])
        registry.register_signatures(:sum, NUMERIC_VARIADIC)
        registry.register_signatures(:avg, NUMERIC_VARIADIC)
        registry.register_signatures(:min, NUMERIC_VARIADIC)
        registry.register_signatures(:max, NUMERIC_VARIADIC)
        registry.register_signatures(:mul, NUMERIC_VARIADIC)
        registry.register_signatures(:and, LOGICAL_VARIADIC)
        registry.register_signatures(:or, LOGICAL_VARIADIC)
        registry.register_signatures(:xor, LOGICAL_VARIADIC)
        registry.register_signatures(:not, [{ params: [[:logical, :nil]], return: :logical }])
        registry.register_signatures(:intercept, [
          { params: [{ array: :numeric }, { array: :numeric }], return: :numeric }
        ])
        registry.register_signatures(:left, [{ params: [:any, :numeric], return: :string }])
        registry.register_signatures(:right, [{ params: [:any, :numeric], return: :string }])
        registry.register_signatures(:mid, [{ params: [:any, :numeric, :numeric], return: :string }])
        registry.register_signatures(:len, [{ params: [:any], return: :numeric }])
        registry.register_signatures(:find, [{ params: [:any, :any], return: [:numeric, :nil] }])
        registry.register_signatures(:substitute, [{ params: [:any, :any, :any], return: :string }])
        registry.register_signatures(:concat, [{ params: [{ variadic: :any }], return: :string }])
        registry.register_signatures(:contains, [{ params: [:any, :any], return: :logical }])

        Math.methods(false).each do |method|
          function_class = AST::Function.registry.get(method)
          min = function_class.min_param_count
          max = function_class.max_param_count
          signatures = if max == Float::INFINITY
                         [{ params: [{ variadic: :numeric }], return: :numeric }]
                       else
                         Array(min..max).map { |count| { params: Array.new(count) { :numeric }, return: :numeric } }
                       end
          registry.register_signatures(method, signatures)
        end
      end
    end

  end

  TypeSignatures.register!
end
