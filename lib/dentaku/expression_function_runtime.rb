require 'dentaku/exceptions'

module Dentaku
  # Per-evaluation runtime state shared by all expression-defined function
  # calls: it enforces the call-depth and operation-count budgets and
  # tracks the chain of active calls so errors can report it.
  #
  # A fresh runtime is merged into the evaluation context by
  # Calculator#evaluation_context, so every top-level evaluate/evaluate!
  # gets its own budgets and nothing leaks into the calculator memory
  # afterwards (Calculator#store restores the context keys it touched).
  class ExpressionFunctionRuntime
    CONTEXT_KEY = "__expression_function_runtime".freeze

    DEFAULT_MAX_DEPTH = 64
    DEFAULT_MAX_OPERATIONS = 10_000

    attr_reader :max_depth, :max_operations, :operations, :call_stack

    def initialize(max_depth: DEFAULT_MAX_DEPTH, max_operations: DEFAULT_MAX_OPERATIONS)
      @max_depth = max_depth
      @max_operations = max_operations
      @operations = 0
      @call_stack = []
    end

    # Returns the runtime for this evaluation, creating one on the fly for
    # callers that evaluate a node directly without going through a
    # calculator (budgets then fall back to the defaults).
    def self.fetch(context)
      context[CONTEXT_KEY] ||= new
    end

    def enter(definition)
      @operations += 1
      label = definition.label

      if @operations > @max_operations
        raise FunctionBudgetError.new(:operations, @max_operations, @call_stack, label)
      end

      if @call_stack.length >= @max_depth
        raise FunctionBudgetError.new(:depth, @max_depth, @call_stack, label)
      end

      @call_stack.push(label)
    end

    def exit
      @call_stack.pop
    end
  end
end
