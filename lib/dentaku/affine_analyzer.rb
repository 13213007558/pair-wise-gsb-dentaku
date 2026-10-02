require 'rational'
require 'dentaku/ast'
require 'dentaku/exceptions'

module Dentaku
  # A symbolic affine expression: constant + sum(coefficient * variable).
  # All arithmetic is exact (Integer/Rational); Float and BigDecimal
  # constants coming out of parsed literals are rationalized so that decimal
  # literals such as 0.2 never lose precision (0.2 becomes 1/5, not 1/5 +/- epsilon).
  class AffineExpression
    attr_reader :coeffs, :constant

    def initialize(coeffs = {}, constant = 0)
      @coeffs = coeffs.reject { |_, v| v.zero? }
      @constant = constant
    end

    def self.constant(value)
      new({}, rationalize(value))
    end

    def self.variable(name)
      new({ name => 1 }, 0)
    end

    def +(other)
      other = self.class.constant(other) unless other.is_a?(self.class)
      self.class.new(coeffs.merge(other.coeffs) { |_, a, b| a + b }, constant + other.constant)
    end

    def -(other)
      self + (-other)
    end

    def -@
      self.class.new(coeffs.transform_values { |v| -v }, -constant)
    end

    def *(other)
      other = self.class.constant(other) unless other.is_a?(self.class)

      if constant?
        other.scale(constant)
      elsif other.constant?
        scale(other.constant)
      else
        nil
      end
    end

    def /(other)
      other = self.class.constant(other) unless other.is_a?(self.class)
      return nil unless other.constant?
      return nil if other.constant.zero?

      scale(Rational(1, 1) / other.constant)
    end

    def constant?
      coeffs.empty?
    end

    # evaluate with concrete numeric bindings; unbound variables raise
    def evaluate(bindings = {})
      sum = constant
      coeffs.each do |name, coefficient|
        sum += coefficient * self.class.rationalize(
          bindings.fetch(name) { raise Dentaku::UnboundVariableError.new([name]) }
        )
      end
      sum
    end

    # exact presentation: Integer for whole values, a terminating BigDecimal
    # for decimal results, Rational for everything else
    def self.exactify(value)
      value = rationalize(value)
      return value.to_i if value.denominator == 1

      terminating_decimal(value) || value
    end

    def self.rationalize(value)
      case value
      when Rational, Integer
        value
      when BigDecimal
        Rational(value.to_s)
      when Float
        value.rationalize
      else
        Rational(value)
      end
    end

    # 10^k = 2^k * 5^k, so a fraction terminates in decimal exactly when the
    # denominator has no prime factors other than 2 and 5
    def self.terminating_decimal(rational)
      denominator = rational.denominator
      twos = 0
      fives = 0
      until denominator == 1
        if denominator % 2 == 0
          denominator /= 2
          twos += 1
        elsif denominator % 5 == 0
          denominator /= 5
          fives += 1
        else
          return nil
        end
      end
      places = [twos, fives].max
      multiplier = 10 ** places / rational.denominator
      unscaled = rational.numerator * multiplier
      BigDecimal(unscaled.to_s) / BigDecimal((10 ** places).to_s)
    end

    protected

    def scale(factor)
      self.class.new(coeffs.transform_values { |v| v * factor }, constant * factor)
    end
  end

  # Statically analyses an AST into an AffineExpression with respect to a set
  # of unknown names (the variables of one dependency cycle).
  #
  # Linearity is decided from the expression *structure*, never by sampling
  # values and guessing. Multiplication and division are affine only when one
  # side provably has no dependency on an unknown (multiplication: either
  # side; division: the divisor); anything else raises NonLinearEquationError
  # attributed to the top-level formula being analysed.
  class AffineAnalyzer
    def initialize(calculator, unknowns, formula_name, context = nil)
      @calculator = calculator
      @unknowns = unknowns
      @formula_name = formula_name
      @context = context
      @external_visits = Set.new
    end

    def analyze(node)
      case node
      when AST::Numeric
        AffineExpression.constant(node.value)
      when AST::Identifier
        analyze_identifier(node)
      when AST::Grouping
        analyze(node.node)
      when AST::Negation
        -analyze(node.node)
      when AST::Addition
        analyze(node.left) + analyze(node.right)
      when AST::Subtraction
        analyze(node.left) - analyze(node.right)
      when AST::Multiplication
        multiply(node)
      when AST::Division
        divide(node)
      when AST::Percentage
        analyze(node.left) * AffineExpression.constant(BigDecimal('0.01'))
      else
        if depends_on_unknown?(node)
          nonlinear!(node)
        else
          fold_constant(node)
        end
      end
    end

    private

    def analyze_identifier(node)
      name = standardize(node.identifier)
      return AffineExpression.variable(name) if @unknowns.include?(name)

      external = lookup(name)
      if external.is_a?(AST::Node)
        # a formula stored in memory only participates in a cycle through
        # transitive references; guard against those cycles here
        unless @external_visits.add?(name)
          raise TSort::Cyclic, "cyclic dependency involving #{name}"
        end
        analyzed = analyze(external)
        @external_visits.delete(name)
        analyzed
      elsif bound?(name)
        constant_value(lookup(name), node)
      else
        raise Dentaku::UnboundVariableError.new([name])
      end
    end

    def multiply(node)
      left = analyze(node.left)
      right = analyze(node.right)
      left * right || nonlinear!(node, operator: '*')
    end

    def divide(node)
      numerator = analyze(node.left)
      denominator = analyze(node.right)
      if denominator.constant? && denominator.constant.zero? && !depends_on_unknown?(node.right)
        raise Dentaku::ZeroDivisionError
      end
      numerator / denominator || nonlinear!(node, operator: '/')
    end

    # every unknown reachable from this node, including through formulas held
    # in calculator memory; purely syntactic, evaluates nothing
    def depends_on_unknown?(node, seen = Set.new)
      static_names(node).any? do |name|
        next true if @unknowns.include?(name)

        external = effective_context[name]
        next false unless external.is_a?(AST::Node)
        next false unless seen.add?([name, external.object_id])

        depends_on_unknown?(external, seen)
      end
    end

    def static_names(node)
      node.dependencies(AST::Node::STATIC_CONTEXT).map { |name| standardize(name) }
    end

    def fold_constant(node)
      value = node.value(effective_context)
      AffineExpression.constant(value)
    rescue Dentaku::Error
      raise
    rescue StandardError
      nonlinear!(node)
    end

    def constant_value(value, node)
      if value.is_a?(::String) && Dentaku::NumericParser.parse_string(value).nil?
        nonlinear!(node)
      end
      AffineExpression.constant(value)
    end

    def nonlinear!(node, operator: nil)
      raise Dentaku::NonLinearEquationError.new(
        formula: @formula_name,
        operator: operator,
        node: node
      )
    end

    def lookup(name)
      effective_context[name]
    end

    def standardize(name)
      @calculator.case_sensitive ? name : name.downcase
    end

    def bound?(name)
      effective_context.key?(name)
    end

    def effective_context
      @context || @calculator.memory
    end
  end
end
