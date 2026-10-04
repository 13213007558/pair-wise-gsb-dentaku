require 'set'

module Dentaku
  class EvaluationTracker
    CONTEXT_KEY = "__dentaku_evaluation_tracker__".freeze

    Frame = Struct.new(:dependencies, :volatile, :functions, keyword_init: true)

    def initialize
      @frames = [new_frame]
      @local_scopes = [[]]
    end

    def read(identifier)
      current_frame.dependencies << identifier unless local?(identifier)
    end

    def new_formula_frame
      new_frame
    end

    def with_formula(frame = new_frame)
      @frames.push(frame)
      yield(frame)
    ensure
      @frames.pop
      frame
    end

    def dependencies
      current_frame.dependencies.uniq
    end

    def volatile?
      current_frame.volatile
    end

    def mark_volatile!
      current_frame.volatile = true
    end

    def use_function(name, version)
      current_frame.functions[name] = version
    end

    def function_versions
      current_frame.functions.dup
    end

    def frame
      current_frame
    end

    def with_locals(*identifiers)
      @local_scopes.push(identifiers.flatten.map(&:to_s))
      yield
    ensure
      @local_scopes.pop
    end

    private

    def new_frame
      Frame.new(dependencies: Set.new, volatile: false, functions: {})
    end

    def current_frame
      @frames.last
    end

    def local?(identifier)
      @local_scopes.last.any? do |name|
        identifier == name || identifier.start_with?("#{name}.")
      end
    end
  end
end
