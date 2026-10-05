require "dentaku/calculator"
require_relative "type_check/types"
require_relative "type_check/constraint"
require_relative "type_check/solver"
require_relative "type_check/signature"
require_relative "type_check/builtins"
require_relative "type_check/result"
require_relative "type_check/checker"

module Dentaku
  # Static type checking for formulas, before any data exists: given
  # variable type declarations and function signatures, computes the
  # result type of an expression without evaluating it, or reports the
  # set of mutually conflicting constraints.
  #
  #   checker = Dentaku::TypeChecker.new(
  #     variables: { "price" => :numeric, "tags" => [:array, :string] },
  #     functions: { "first_of" => { params: [[:array, :a]], returns: :a } }
  #   )
  #   checker.check("price * 2").type_spec       # => :numeric
  #   checker.check("concat(price, '!')").ok?    # => false
  class TypeChecker
    def initialize(variables: {}, functions: {}, calculator: nil, case_sensitive: nil)
      calculator ||= Dentaku::Calculator.new
      case_sensitive = calculator.case_sensitive if case_sensitive.nil?
      @checker = TypeCheck::Checker.new(
        variables: variables,
        functions: functions,
        calculator: calculator,
        case_sensitive: case_sensitive
      )
    end

    # check a single expression, returning a TypeCheck::Result
    def check(expression)
      @checker.check(expression)
    end

    # check several formulas that build on each other: each formula's
    # result type becomes the type of its name for the formulas that
    # follow, so conflicts that only appear once formulas are connected
    # surface here. Returns { name => Result } in insertion order.
    def check_all(formulas)
      formulas.each_with_object({}) do |(name, expression), results|
        result = @checker.check(expression, formula: name)
        term = result.ok? ? result.term : @checker.unknown_formula_term(name, result.node)
        @checker.bind_formula_result(name, term, result.node)
        results[name.to_s] = result
      end
    end
  end
end
