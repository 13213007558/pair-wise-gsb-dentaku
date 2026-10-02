require 'set'
require 'dentaku/affine_expression'

module Dentaku
  class AffineExpressionBuilder
    def initialize(context = {}, active_variables = [])
      @context = context
      @active_variables = active_variables.map(&:to_s)
      @visiting = Set.new
    end

    def build(node)
      case node
      when AST::Numeric
        AffineExpression.constant(AffineExpression.exact(node.value))
      when AST::Identifier
        build_identifier(node)
      when AST::Grouping
        build(node.instance_variable_get(:@node))
      when AST::Negation
        -build(node.instance_variable_get(:@node))
      when AST::Percentage
        build(node.instance_variable_get(:@left)).scale(Rational(1, 100))
      when AST::Addition
        build(node.left) + build(node.right)
      when AST::Subtraction
        build(node.left) - build(node.right)
      when AST::Multiplication
        build(node.left) * build(node.right)
      when AST::Division
        build(node.left) / build(node.right)
      when AST::Modulo
        build(node.left) % build(node.right)
      when AST::Exponentiation
        build(node.left) ** build(node.right)
      when AST::If
        build_if(node)
      when AST::Case
        build_case(node)
      when AST::Function
        build_function(node)
      when AST::Literal
        value = node.value
        raise NonlinearExpressionError unless value.is_a?(::Numeric)

        AffineExpression.constant(AffineExpression.exact(value))
      else
        if uses_active_variable?(node)
          raise NonlinearExpressionError
        end

        AffineExpression.constant(node.value(@context))
      end
    rescue NonlinearExpressionError
      raise
    rescue ZeroDivisionError
      raise Dentaku::ZeroDivisionError
    end

    private

    attr_reader :context, :active_variables

    def build_identifier(node)
      name = node.identifier
      return AffineExpression.variable(name) if active_variables.include?(name)
      return AffineExpression.variable(name) if @visiting.include?(name)

      unless context.key?(name)
        raise UnboundVariableError.new([name]),
              "no value provided for variables: #{name}"
      end

      value = context.fetch(name)
      case value
      when AffineExpression
        value
      when AST::Node
        @visiting.add(name)
        begin
          build(value)
        ensure
          @visiting.delete(name)
        end
      when Numeric
        AffineExpression.constant(AffineExpression.exact(value))
      else
        raise NonlinearExpressionError
      end
    end

    def build_if(node)
      raise NonlinearExpressionError if uses_active_variable?(node.predicate)
      branch = node.predicate.value(context) ? node.left : node.right
      build(branch)
    end

    def build_case(node)
      switch_node = node.switch.instance_variable_get(:@node)
      raise NonlinearExpressionError if uses_active_variable?(switch_node)
      switch_value = switch_node.value(context)

      node.conditions.each do |condition|
        when_node = condition.when.node
        raise NonlinearExpressionError if uses_active_variable?(when_node)
        next unless when_node.value(context) == switch_value

        return build(condition.then.node)
      end

      raise NonlinearExpressionError unless node.else

      build(node.else.instance_variable_get(:@node))
    end

    def build_function(node)
      raise NonlinearExpressionError if uses_active_variable?(node)

      value = node.value(context)
      AffineExpression.constant(AffineExpression.exact(value))
    rescue NonlinearExpressionError
      raise
    rescue NoMethodError, ::TypeError, ::ArgumentError
      raise NonlinearExpressionError
    end

    def uses_active_variable?(node)
      return false unless node.respond_to?(:dependencies)

      (node.dependencies(AST::Node::STATIC_CONTEXT) & active_variables).any?
    end
  end
end
