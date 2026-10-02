require 'bigdecimal'

module Dentaku
  class GradientResult < Hash
    def initialize(value, gradient)
      super()
      self[:value] = value
      self[:result] = value
      self[:gradient] = gradient
    end

    def value
      self[:value]
    end
    alias_method :result, :value

    def gradient
      self[:gradient]
    end
    alias_method :gradients, :gradient
  end

  class GradientEvaluator
    def initialize(context, variables, function_registry)
      @context = context
      @variables = variables.map { |name| name.to_s }
      @function_registry = function_registry
      @zero = Hash[@variables.map { |name| [name, 0] }]
    end

    def evaluate(node)
      dual = evaluate_node(node)
      return dual.value, dual.gradient if dual.value.is_a?(::Numeric)

      raise Dentaku::DifferentiationError.for(
        :non_numeric_result, actual: dual.value
      )
    end

    private

    Dual = Struct.new(:value, :gradient)

    def gradient_for(source)
      source ? { source => 1 }.merge(@zero) { |_key, chosen, _zero| chosen } : @zero.dup
    end

    def const(value)
      Dual.new(value, @zero.dup)
    end

    def call_private(node, name, *args)
      node.class.instance_method(name).bind_call(node, *args)
    end

    def combine(values, coefficients)
      values.each_with_index.reduce(@zero.dup) do |gradient, (dual, index)|
        add_gradient(gradient, combine_dual(dual, coefficients[index]))
      end
    end

    def combine_dual(dual, coefficient)
      return dual.gradient.dup unless coefficient

      gradient = nested_gradient(dual.value, dual.gradient, coefficient)
      gradient.is_a?(::Hash) ? gradient : scale_gradient(dual.gradient, gradient)
    end

    def nested_gradient(value, fallback, coefficient)
      unless value.is_a?(::Array) && coefficient.is_a?(::Array)
        return fallback.transform_values { |item| item * coefficient }
      end

      value.each_with_index.reduce(fallback.dup) do |gradient, (item, index)|
        add_gradient(
          gradient,
          nested_gradient(item.value, item.gradient, coefficient[index])
        )
      end
    end

    def add_gradient(left, right)
      left.merge(right) { |_key, l, r| l + r }
    end

    def scale_gradient(gradient, coefficient)
      gradient.each_with_object({}) { |(key, value), result|
        result[key] = value * coefficient
      }
    end

    def flatten_dual(value, path = [])
      case value
      when Dual
        [[path, value]]
      when Array
        value.flat_map.with_index { |item, index| flatten_dual(item, path + [index]) }
      else
        []
      end
    end

    def dual_leaves(value)
      case value
      when Dual
        nested_leaves(value)
      when Array
        value.flat_map { |item| dual_leaves(item) }
      else
        []
      end
    end

    def nested_leaves(dual)
      return [dual] unless dual.value.is_a?(::Array)

      dual.value.flat_map { |item| nested_leaves(item) }
    end

    def primal(value)
      case value
      when Dual then primal(value.value)
      when Array then value.map { |item| primal(item) }
      else value
      end
    end

    def evaluate_node(node)
      case node
      when AST::If then evaluate_if(node)
      when AST::Negation then evaluate_unary(node, :-, node.node)
      when AST::Percentage then evaluate_percentage(node)
      when AST::Addition, AST::Subtraction then evaluate_additive(node)
      when AST::Multiplication then evaluate_binary(node)
      when AST::Division then evaluate_division(node)
      when AST::Modulo then evaluate_modulo(node)
      when AST::Exponentiation then evaluate_power(node)
      when AST::Comparator then evaluate_comparator(node)
      when AST::And, AST::Or then evaluate_short_circuit(node)
      when AST::Access then evaluate_access(node)
      when AST::Function then evaluate_function(node)
      when AST::Identifier then evaluate_identifier(node)
      when AST::Grouping then evaluate_node(node.instance_variable_get(:@node))
      when AST::Array
        Dual.new(
          node.instance_variable_get(:@elements).map { |arg| evaluate_node(arg) },
          @zero.dup
        )
      when AST::Literal then const(node.value(@context))
      when AST::Nil then const(nil)
      else
        raise Dentaku::DifferentiationError.for(
          :unsupported_expression,
          expression: node.class.name || node.class.inspect
        )
      end
    end

    def evaluate_unary(node, operator, child_node)
      child = evaluate_node(child_node)
      value = call_private(node, :cast, child.value) * -1
      Dual.new(value, scale_gradient(child.gradient, operator == :- ? -1 : 1))
    end

    def evaluate_percentage(node)
      child = evaluate_node(node.instance_variable_get(:@left))
      Dual.new(child.value * 0.01, scale_gradient(child.gradient, 0.01))
    end

    def evaluate_additive(node)
      left = evaluate_node(node.left)
      right = evaluate_node(node.right)
      if node.left.type == :datetime || call_private(node, :datetime?, left.value)
        operation = node.operator == :+ ? :add : :sub
        return const(Dentaku::DateArithmetic.new(left.value).public_send(operation, right.value))
      end

      Dual.new(
        call_private(node, :calculate, left.value, right.value),
        add_gradient(
          left.gradient,
          scale_gradient(right.gradient, node.operator == :- ? -1 : 1)
        )
      )
    end

    def evaluate_binary(node)
      left = evaluate_node(node.left)
      right = evaluate_node(node.right)
      left_value = call_private(node, :cast, left.value)
      right_value = call_private(node, :cast, right.value)
      value = left_value.public_send(:*, right_value)
      call_private(node, :validate_result, value, left_value, right_value)
      gradient = add_gradient(
        scale_gradient(left.gradient, right.value.to_f),
        scale_gradient(right.gradient, left.value.to_f)
      )
      Dual.new(value, gradient)
    end

    def evaluate_division(node)
      left = evaluate_node(node.left)
      right = evaluate_node(node.right)
      denominator = call_private(node, :decimal, call_private(node, :cast, right.value))
      raise Dentaku::ZeroDivisionError if denominator.zero?

      value = call_private(node, :cast, call_private(node, :cast, left.value) / denominator)
      gradient = add_gradient(
        scale_gradient(left.gradient, 1.0 / right.value.to_f),
        scale_gradient(right.gradient, -left.value.to_f / (right.value.to_f**2))
      )
      Dual.new(value, gradient)
    end

    def evaluate_modulo(node)
      left = evaluate_node(node.left)
      right = evaluate_node(node.right)
      denominator = call_private(node, :decimal, call_private(node, :cast, right.value))
      raise Dentaku::ZeroDivisionError if denominator.zero?

      value = call_private(node, :cast, call_private(node, :cast, left.value) % denominator)
      if value.zero?
        raise non_differentiable(node, "#{left.value} % #{right.value} = 0")
      end

      quotient = ((left.value - value) / right.value).to_i
      gradient = add_gradient(
        scale_gradient(left.gradient, 1),
        scale_gradient(right.gradient, -quotient)
      )
      Dual.new(value, gradient)
    end

    def evaluate_power(node)
      left = evaluate_node(node.left)
      right = evaluate_node(node.right)
      value = begin
        left.value.public_send(:**, right.value)
      rescue Dentaku::Error
        raise
      rescue ::RangeError, ::FloatDomainError, ::TypeError => error
        raise Dentaku::ArgumentError.for(:invalid_value, actual: right.value), error.message
      end

      power_gradient(node, left, right, value)
    end

    def power_gradient(node, left, right, value)
      x = left.value
      y = right.value
      exponent_integer = integer_exponent?(y)
      exponent_variable = right.gradient.values.any? { |value| value != 0 }

      if x.zero?
        return Dual.new(value, left.gradient.dup) if y == 1
        return Dual.new(value, @zero.dup) if y.is_a?(::Integer) && y > 1 && !exponent_variable

        raise non_differentiable(node, "x = 0, y = #{y}")
      end

      if x.negative? && exponent_integer && !exponent_variable
        left_coefficient = y.to_f * ((x**(y - 1)).to_f)
        right_coefficient = value.to_f * Math.log(-x.to_f)
      elsif x.negative?
        raise non_differentiable(node, "x = #{x}, y = #{y}")
      else
        left_coefficient = y.to_f * value.to_f / x.to_f
        right_coefficient = value.to_f * Math.log(x.to_f)
      end

      gradient = add_gradient(
        scale_gradient(left.gradient, left_coefficient),
        scale_gradient(right.gradient, right_coefficient)
      )
      Dual.new(value, gradient)
    end

    def integer_exponent?(value)
      return value.integer? if value.respond_to?(:integer?)

      numeric?(value) && value == value.to_i
    end

    def evaluate_comparator(node)
      left = evaluate_node(node.left)
      right = evaluate_node(node.right)
      if node.is_a?(AST::Equal) || node.is_a?(AST::NotEqual)
        if numeric?(left.value) && numeric?(right.value) && left.value == right.value
          raise non_differentiable(node, "#{left.value} = #{right.value}")
        end
      elsif left.value == right.value
        raise non_differentiable(node, "#{left.value} = #{right.value}")
      end

      left_value = call_private(node, :validate_value, call_private(node, :cast, left.value))
      right_value = call_private(node, :validate_value, call_private(node, :cast, right.value))
      value = left_value.public_send(node.operator, right_value)
      Dual.new(value, @zero.dup)
    rescue ::ArgumentError, ::TypeError => error
      raise Dentaku::ArgumentError.for(
        :incompatible_type, actual: right_value, expected: left_value.class
      ), error.message
    end

    def evaluate_short_circuit(node)
      left = evaluate_node(node.left)
      decisive = node.is_a?(AST::And) ? !left.value : !!left.value
      value = if decisive
                left.value
              else
                right = evaluate_node(node.right)
                right.value
              end
      Dual.new(value, @zero.dup)
    end

    def evaluate_access(node)
      structure = evaluate_node(node.instance_variable_get(:@structure))
      index = evaluate_node(node.instance_variable_get(:@index))
      if index.gradient.values.any? { |value| value != 0 }
        raise Dentaku::DifferentiationError.for(
          :unsupported_expression, expression: 'array index'
        )
      end

      selected = structure.value[index.value]
      selected.is_a?(Dual) ? selected : const(selected)
    end

    def evaluate_if(node)
      predicate = evaluate_node(node.predicate)
      predicate_value = predicate.is_a?(Dual) ? predicate.value : predicate
      selected = predicate_value ? evaluate_node(node.left) : evaluate_node(node.right)
      Dual.new(selected.value, selected.gradient.dup)
    end

    def evaluate_identifier(node)
      name = node.identifier
      value = node.value(@context)
      return const(value) unless @variables.include?(name)

      unless value.is_a?(::Numeric)
        raise Dentaku::ArgumentError.for(:incompatible_type, actual: value, expected: Numeric)
      end

      Dual.new(value, gradient_for(name))
    end

    def evaluate_function(node)
      name = function_name(node)
      return evaluate_built_in_function(node, name) if built_in_function?(name)
      return const(node.value(@context)) unless node.type == :numeric

      rule = @function_registry.derivative(name)
      unless rule
        node.value(@context)
        raise Dentaku::DifferentiationError.for(
          :unsupported_function, function_name: name.upcase
        )
      end

      args = node.args.map { |arg| evaluate_node(arg) }
      primal = primal_function(node, args)
      coefficients = rule.call(*primal(args))
      gradient = if single_array_argument?(args) && coefficients.is_a?(::Array)
                   combine_dual(args.first, coefficients)
                 else
                   coefficients = [coefficients] if node.args.length > 1 && !coefficients.is_a?(::Array)
                   combine(args, Array(coefficients))
                 end
      Dual.new(primal, gradient)
    end

    def evaluate_built_in_function(node, name)
      if node.is_a?(AST::RubyMath)
        args = node.args.map { |arg| evaluate_node(arg) }
        primal = math_primal(node, args)
        unless primal.is_a?(::Numeric)
          raise Dentaku::DifferentiationError.for(
            :unsupported_function, function_name: name.upcase
          )
        end

        return Dual.new(primal, built_in_gradient(node, name, args, primal))
      end

      if differentiable_aggregate?(name)
        args = node.args.map { |arg| evaluate_node(arg) }
        return Dual.new(primal_function(node, args), built_in_gradient(node, name, args))
      end

      primal = node.value(@context)
      return const(primal) unless node.type == :numeric && primal.is_a?(::Numeric)

      raise Dentaku::DifferentiationError.for(
        :unsupported_function, function_name: name.upcase
      )
    end

    def differentiable_aggregate?(name)
      %w[abs min max sum avg mul round roundup rounddown].include?(name)
    end

    def single_array_argument?(args)
      args.length == 1 && args.first.value.is_a?(::Array)
    end

    def math_primal(node, args)
      values = flatten_dual(args).map { |_path, dual| dual.value }
      node.class.call(*values)
    end

    def primal_function(node, args)
      if node.class.respond_to?(:implementation)
        node.class.implementation.call(*primal(args))
      else
        node.value(@context)
      end
    end

    def built_in_gradient(node, name, args, primal = nil)
      case name
      when 'abs' then abs_gradient(node, args)
      when 'min', 'max' then extreme_gradient(node, name, args)
      when 'sum' then aggregate_gradient(args, 1, flatten: false)
      when 'avg' then aggregate_gradient(args, 1.0 / flatten_dual(args).length, flatten: false)
      when 'mul' then mul_gradient(args)
      when 'round', 'roundup', 'rounddown' then round_gradient(node, name, args)
      else
        rule = @function_registry.derivative(name)
        if rule
          values = flatten_dual(args).map { |_path, dual| dual.value }
          coefficients = rule.call(*values)
          return combine_flat(args, Array(coefficients))
        end
        raise Dentaku::DifferentiationError.for(
          :unsupported_function, function_name: name.upcase
        )
      end
    end

    def abs_gradient(node, args)
      value = args.first.value
      raise non_differentiable(node, 'x = 0') if value.zero?

      scale_gradient(args.first.gradient, value.positive? ? 1 : -1)
    end

    def extreme_gradient(node, name, args)
      leaves = dual_leaves(args)
      values = leaves.map(&:value)
      selected = values.public_send(name)
      winners = values.each_index.select { |index| values[index] == selected }

      if winners.length > 1
        raise non_differentiable(node, winners.map { |index| values[index] }.uniq.join(', '))
      end

      leaves[winners.first].gradient.dup
    end

    def aggregate_gradient(args, coefficient, flatten: true)
      leaves = if flatten
                 dual_leaves(args)
               else
                 dual_leaves(args)
               end
      leaves.reduce(@zero.dup) do |gradient, dual|
        add_gradient(gradient, scale_gradient(dual.gradient, coefficient))
      end
    end

    def mul_gradient(args)
      values = leaves.map(&:value)
      values.each_with_index.reduce(@zero.dup) do |gradient, (_value, index)|
        coefficient = values.each_with_index.reduce(1.0) do |product, (other, other_index)|
          other_index == index ? product : product * other.to_f
        end
        add_gradient(gradient, scale_gradient(leaves[index].gradient, coefficient))
      end
    end

    def round_gradient(node, name, args)
      value = args[0].value
      places = args.length > 1 ? args[1].value : 0
      if args.length > 1 && flatten_dual(args[1]).any? { |_path, dual| dual.gradient.values.any? { |d| d != 0 } }
        raise non_differentiable(node, "places = #{places}")
      end

      scale = BigDecimal((10**places.to_i).to_s)
      scaled = BigDecimal(value.to_s) * scale
      boundary = case name
                 when 'round' then scaled.frac.abs == 0.5
                 when 'roundup' then scaled.frac.zero?
                 else scaled.frac.zero?
                 end
      raise non_differentiable(node, "x = #{value}") if boundary

      @zero.dup
    end

    def built_in_function?(name)
      registered = @function_registry.get(name)
      return false unless registered

      if @function_registry.key?(name)
        AST::FunctionRegistry.default.key?(name) &&
          AST::FunctionRegistry.default.get(name).equal?(registered)
      else
        true
      end
    end

    def combine_flat(args, coefficients)
      leaves = flatten_dual(args)
      combine_leaves(leaves, coefficients)
    end

    def combine_leaves(leaves, coefficients)
      leaves.each_with_index.reduce(@zero.dup) do |gradient, ((_path, dual), index)|
        add_gradient(gradient, scale_gradient(dual.gradient, coefficients[index].to_f))
      end
    end

    def function_name(node)
      return node.class.name.to_s.downcase if node.is_a?(AST::RubyMath)

      class_name = node.class.name.to_s.split('::').last
      registry_name = @function_registry.keys.find do |name|
        registered = @function_registry.get(name)
        registered.equal?(node.class)
      end
      return registry_name if registry_name

      default_name = AST::FunctionRegistry.default.keys.find do |name|
        AST::FunctionRegistry.default.get(name).equal?(node.class)
      end
      return default_name if default_name

      class_name == 'Class' ? node.to_s.downcase : class_name.downcase
    rescue StandardError
      node.to_s.downcase
    end

    def non_differentiable(node, point)
      Dentaku::DifferentiationError.for(
        :non_differentiable,
        name: display_name(node),
        point: point
      )
    end

    def display_name(node)
      node.respond_to?(:display_operator) ? node.display_operator : function_name(node).upcase
    end

    def numeric?(value)
      value.is_a?(::Numeric)
    end
  end
end
