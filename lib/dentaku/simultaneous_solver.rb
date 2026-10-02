require 'dentaku/affine_analyzer'
require 'dentaku/exceptions'
require 'dentaku/print_visitor'

module Dentaku
  # Outcome of solving one or more dependency cycles simultaneously.
  #
  #   solution.status  -> :unique | :inconsistent | :family
  #   solution.unique? / inconsistent? / family?
  #   solution.free_variables -> names of free parameters (family only)
  #   solution.solution_for(name, bindings = {}) -> numeric value or the
  #     parametric AffineExpression when name is a pivot in a family
  #
  # For unique systems #values is a plain variable => numeric hash and #to_h
  # returns the same mapping. For families #to_h(bindings) instantiates a
  # member of the solution family (free parameters default to 0).
  class SimultaneousSolution
    attr_reader :status, :values, :free_variables, :verified

    def initialize(status, values, free_variables: [], verified: false)
      @status = status
      @values = values
      @free_variables = free_variables
      @verified = verified
    end

    def unique?
      status == :unique
    end

    def family?
      status == :family
    end

    def inconsistent?
      status == :inconsistent
    end

    def verified?
      verified
    end

    def solution_for(name, bindings = {})
      expression = values.fetch(name.to_s) { values.fetch(name.to_s.downcase, nil) }
      raise KeyError, "#{name} is not part of the solved system" if expression.nil?
      return expression unless expression.is_a?(AffineExpression)

      AffineExpression.exactify(expression.evaluate(normalize(bindings)))
    end

    def to_h(bindings = {})
      return values unless family?
      bindings = default_bindings(bindings)

      values.transform_values do |expression|
        next expression unless expression.is_a?(AffineExpression)

        AffineExpression.exactify(expression.evaluate(normalize(bindings)))
      end
    end

    def [](name)
      solution_for(name)
    end

    def fetch(*args, &block)
      values.fetch(*args, &block)
    end

    def key?(name)
      values.key?(name.to_s) || values.key?(name.to_s.downcase)
    end

    def ==(other)
      other.respond_to?(:values) ? values == other.values : values == other
    end

    private

    def default_bindings(bindings)
      normalized = bindings.each_with_object({}) { |(name, value), h| h[name.to_s] = value }
      free_variables.each { |name| normalized[name] ||= 0 }
      normalized
    end

    def normalize(bindings)
      bindings.each_with_object({}) do |(name, value), h|
        h[name.to_s] = value
      end
    end
  end

  # Solves a strongly connected component of formulas as a numeric linear
  # system. Every formula is first proven affine in the cycle's unknowns by
  # AffineAnalyzer (structural proof, no value sampling), then the resulting
  # exact equations are reduced by Gauss-Jordan elimination.
  class SimultaneousSolver
    TOLERANCE = 1e-12

    def initialize(calculator, equations, context)
      # equations: variable name => parsed AST
      @calculator = calculator
      @equations = equations
      @context = context
    end

    def solve
      unknowns = equations.keys
      expressions = equations.map do |name, ast|
        [name, AffineAnalyzer.new(calculator, unknowns, name, context).analyze(ast)]
      end

      matrix = expressions.map { |name, affine| to_row(affine, unknowns, name) }
      reduced, pivot_columns, sources = gauss_jordan(matrix)

      contradictory = contradictory_rows(reduced, sources, pivot_columns.length)
      unless contradictory.empty?
        raise Dentaku::InconsistentSystemError.new(
          formulas: contradictory
        )
      end

      values = parameterize(reduced, pivot_columns, unknowns)
      status = pivot_columns.length == unknowns.length ? :unique : :family
      pivot_indices = pivot_columns.map { |column, _| column }
      free = unknowns.each_with_index.reject { |_, index| pivot_indices.include?(index) }.map(&:first)

      solution = SimultaneousSolution.new(status, values, free_variables: free)
      verify!(solution, expressions, unknowns)
      SimultaneousSolution.new(status, values, free_variables: free, verified: true)
    end

    private

    attr_reader :calculator, :equations, :context

    # lhs coefficient vector (coeffs moved to the lhs) + rhs constant; the
    # originating formula name travels separately through elimination so a
    # contradiction can name every equation involved, not just the last row
    def to_row(affine, unknowns, name)
      coefficients = unknowns.map { |unknown| -(affine.coeffs[unknown] || 0) }
      coefficients[unknowns.index(name)] += 1
      [coefficients + [affine.constant], [name]]
    end

    def gauss_jordan(matrix)
      rows = matrix.map { |coefficients, _| coefficients.dup }
      sources = matrix.map { |_, names| names.dup }
      width = matrix.first.first.length - 1
      pivot_columns = []
      row = 0
      row_owner = matrix.map { |_, names| names.first }

      eliminate = lambda do |column, pivot|
        rows[row], rows[pivot] = rows[pivot], rows[row] if pivot != row
        row_owner[row], row_owner[pivot] = row_owner[pivot], row_owner[row] if pivot != row
        sources[row], sources[pivot] = sources[pivot], sources[row] if pivot != row
        pivot_value = rows[row][column]
        (0..width).each { |c| rows[row][c] = Rational(rows[row][c]) / pivot_value }

        rows.each_with_index do |other, index|
          next if index == row || other[column] == 0

          factor = other[column]
          (0..width).each { |c| other[c] -= factor * rows[row][c] }
          sources[index] |= sources[row]
        end

        pivot_columns << [column, row]
        row += 1
      end

      # diagonal pivots first: a variable's own defining row is reserved for
      # that variable's column
      (0...width).each do |column|
        owner_name = equations.keys[column]
        owner_row = row_owner.index(owner_name)
        next if owner_row.nil? || owner_row < row
        next if pivot_columns.map(&:last).include?(owner_row)
        next if rows[owner_row][column] == 0

        eliminate.call(column, owner_row)
      end

      # remaining columns: any still-unused non-zero row
      (0...width).each do |column|
        next if pivot_columns.map(&:first).include?(column)

        used_rows = pivot_columns.map(&:last)
        pivot = rows.each_index.find { |r| !used_rows.include?(r) && rows[r][column] != 0 }
        eliminate.call(column, pivot) if pivot
      end

      [rows, pivot_columns, sources]
    end

    def contradictory_rows(rows, sources, pivot_count)
      non_pivot = rows[pivot_count..] || []
      non_pivot.each_with_index.with_object([]) do |(row, offset), names|
        names.concat(sources[pivot_count + offset]) if row.last != 0
      end.uniq
    end

    def parameterize(rows, pivot_columns, unknowns)
      width = unknowns.length
      pivoted = pivot_columns.map { |column, _| [column, true] }.to_h
      free_indices = (0...width).reject { |column| pivoted[column] }
      unique = free_indices.empty?

      values = {}
      pivot_columns.each do |column, row|
        coeffs = {}
        constant = rows[row][width]
        free_indices.each do |free_column|
          factor = -rows[row][free_column]
          coeffs[unknowns[free_column]] = factor unless factor.zero?
        end
        expression = AffineExpression.new(coeffs, constant)
        values[unknowns[column]] = unique ? AffineExpression.exactify(constant) : expression
      end
      free_indices.each { |column| values[unknowns[column]] = AffineExpression.variable(unknowns[column]) }
      values
    end

    # A solution is only accepted when it reproduces the original formulas.
    # First the exact affine residuals must vanish, then the parsed ASTs are
    # re-evaluated with the solution substituted, using the calculator's own
    # arithmetic (BigDecimal division rounds at its own precision), and must
    # agree within a tight tolerance. Family members are checked at two
    # distinct bindings of every free parameter.
    def verify!(solution, expressions, unknowns)
      bindings_list = solution.family? ? [bindings(unknowns, 0), bindings(unknowns, 7)] : [{}]

      bindings_list.each do |bindings|
        numeric = instantiate(solution, bindings)

        expressions.each do |name, affine|
          recomputed = affine.evaluate(numeric)
          residual = (recomputed - numeric.fetch(name)).abs
          unless residual == 0
            raise Dentaku::SolutionVerificationError.new(
              formula: name, expected: numeric.fetch(name), actual: recomputed
            )
          end

          verify_ast!(name, numeric)
        end
      end
    end

    def bindings(unknowns, value)
      unknowns.each_with_object({}) do |name, h|
        h[name] = value
      end
    end

    def instantiate(solution, bindings)
      solution.values.transform_values do |expression|
        expression.is_a?(AffineExpression) ? expression.evaluate(bindings) : rational(expression)
      end
    end

    def rational(value)
      AffineExpression.rationalize(value)
    end

    def verify_ast!(name, numeric)
      ast = equations.fetch(name)
      expected = ast.value(context.merge(numeric))
      actual = numeric.fetch(name)
      return if values_agree?(expected, actual)

      raise Dentaku::SolutionVerificationError.new(formula: name, expected: expected, actual: actual)
    end

    def values_agree?(expected, actual)
      return true if expected == actual

      e = AffineExpression.rationalize(expected)
      a = AffineExpression.rationalize(actual)
      return false if a.zero? && e != 0

      (e - a).abs <= TOLERANCE * [e.abs, a.abs, 1].max
    end
  end
end
