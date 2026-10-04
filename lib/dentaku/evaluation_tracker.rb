require 'set'

module Dentaku
  class EvaluationTracker
    KEY = :__evaluation_tracker

    attr_reader :dependencies, :volatile

    def initialize
      @dependencies = []
      @volatile = false
      @locals = Set.new
    end

    def self.context(context = {})
      context[KEY]
    end

    def self.locals(context, names)
      tracker = context(context)
      return yield unless tracker

      tracker.add_locals(names) { yield }
    end

    def add_dependency(name)
      identifier = name.to_s
      return if local?(identifier)

      dependencies << identifier
      dependencies.uniq!
    end

    def add_local(name)
      @locals << name.to_s
    end

    def add_locals(names)
      previous = @locals.dup
      Array(names).each { |name| add_local(name) }
      yield
    ensure
      @locals = previous
    end

    def function_volatile!
      @volatile = true
    end

    private

    def local?(identifier)
      @locals.any? { |name| identifier == name || identifier.start_with?("#{name}.") }
    end
  end
end
