require 'dentaku/exceptions'
require 'dentaku/flat_hash'

module Dentaku
  # A suspendable, resumable evaluation of a single expression.
  #
  # `evaluate!` needs every variable up front. A session instead evaluates
  # as far as it can and, the first time it reaches an identifier with no
  # bound value, suspends and reports what it needs:
  #
  #   session = calculator.session("price * quantity + tax", price: 10)
  #   session.suspended?        # => true
  #   session.missing_variables # => ["quantity"]
  #   session.resume(quantity: 3)
  #   session.missing_variables # => ["tax"]
  #   session.resume(tax: 2)
  #   session.result            # => 32
  #
  # Resuming re-walks the expression, but values already produced by
  # (non-volatile) custom functions and variable callbacks are memoized in
  # the session, so side effects never run twice and the outcome matches a
  # single `evaluate!` given all inputs at once. IF/AND/OR keep their usual
  # short-circuit behavior: branches that are not selected never request
  # variables.
  #
  # Each session evaluates against its own copy of the calculator's memory,
  # so concurrent sessions (and the calculator itself) never share mutable
  # state. Nothing is persisted and no async machinery is involved: the
  # session is plain in-memory state, continued by calling `resume` again
  # whenever more data is available.
  class EvaluationSession
    # Reserved context key (like "__evaluation_mode") that threads the
    # session through evaluation without changing any method signatures.
    # A symbol can never collide with a (string) identifier name, and
    # because the context is a plain Hash, nodes that derive sub-contexts
    # with Hash#merge (MAP, FILTER, ...) keep the session reference.
    CONTEXT_KEY = :__evaluation_session

    # Internal control-flow signal raised when evaluation reaches an
    # identifier with no bound value. Deliberately not a StandardError (and
    # not a Dentaku::Error) so that neither AST nodes nor user callbacks can
    # swallow it with a generic rescue.
    class Suspend < Exception; end

    attr_reader :missing_variables, :result, :error

    def initialize(calculator, expression, data = {})
      @calculator = calculator
      @node = calculator.ast(expression)
      @node_cache = {}
      @context = build_context
      @status = :suspended
      @missing_variables = []
      store(data)
      run
    end

    def suspended?
      @status == :suspended
    end

    def completed?
      @status == :completed
    end

    def failed?
      @status == :failed
    end

    def status
      @status
    end

    # Provides more variable values and continues the evaluation. Returns
    # the session itself; inspect `status`/`missing_variables`/`result`/
    # `error` afterwards. Raises SessionStateError once the session has
    # completed or failed.
    def resume(data = {})
      raise SessionStateError, @status if completed? || failed?

      store(data)
      run
      self
    end

    # called from Identifier#value when evaluation reaches an identifier
    # with no bound value
    def suspend_on(identifier)
      @missing_variables << identifier unless @missing_variables.include?(identifier)
      raise Suspend
    end

    # called from Identifier#value when a provided variable fails to
    # produce a value (Proc callback or stored formula raised)
    def resolution_failed(identifier)
      raise ResolutionError, identifier
    end

    # per-session memo of already-computed node values; keyed by node
    # object identity so ASTs shared through the cache stay session-local
    attr_reader :node_cache

    private

    def build_context
      @calculator.memory.dup.tap do |context|
        context["__evaluation_mode"] = :strict
        context[CONTEXT_KEY] = self
      end
    end

    def store(data)
      data = FlatHash.from_hash_with_intermediates(data) if @calculator.nested_data_support
      data.each do |key, value|
        @context[@calculator.standardize_case(key.to_s)] = value
      end
    end

    def run
      @missing_variables = []
      @result = @node.value(@context)
      @status = :completed
    rescue Suspend
      @status = :suspended
    rescue StandardError => e
      @error = e
      @status = :failed
    end
  end
end
