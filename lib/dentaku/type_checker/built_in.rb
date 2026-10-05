module Dentaku
  module TypeChecker
    # Signatures for the functions shipped with Dentaku. Custom functions
    # registered with a typed signature take precedence; custom functions
    # without one remain unknown (they are never evaluated to guess).
    module BuiltIn
      module_function

      def signatures
        @signatures ||= begin
          hash = {}
          entries.each { |name, spec| hash[name.to_s] = Signature.parse(spec) }
          hash
        end
      end

      def [](name)
        signatures[name.to_s.downcase]
      end

      def entries
        [
          # numeric helpers
          ['abs', 'numeric -> numeric'],
          ['round', 'numeric, numeric? -> numeric'],
          ['roundup', 'numeric, numeric? -> numeric'],
          ['rounddown', 'numeric, numeric? -> numeric'],
          ['sqrt', 'numeric -> numeric'],
          ['ln', 'numeric -> numeric'],
          ['log10', 'numeric -> numeric'],
          ['pow', 'numeric, numeric -> numeric'],
          ['min', 'numeric, numeric* -> numeric'],
          ['max', 'numeric, numeric* -> numeric'],
          ['sum', 'array(numeric) -> numeric'],
          ['avg', 'array(numeric) -> numeric'],
          ['mul', 'array(numeric) -> numeric'],
          ['count', 'array(T) -> numeric'],

          # logical
          ['not', 'logical -> logical'],
          ['and', 'logical, logical* -> logical'],
          ['or', 'logical, logical* -> logical'],
          ['xor', 'logical, logical* -> logical'],

          # strings
          ['left', 'string, numeric -> string'],
          ['right', 'string, numeric -> string'],
          ['mid', 'string, numeric, numeric -> string'],
          ['len', 'string -> numeric'],
          ['find', 'string, string -> numeric'],
          ['substitute', 'string, string, string -> string'],
          ['concat', 'string, string* -> string'],
          ['contains', 'string, string -> logical'],

          # higher-order collection functions
          ['map', 'array(T), T -> array(S)'],
          ['filter', 'array(T), T -> array(T)'],
          ['all', 'array(T), T -> logical'],
          ['any', 'array(T), T -> logical'],
          ['reduce', 'array(T), U, T -> U'],

          # dates
          ['duration', 'string, numeric -> duration'],
        ]
      end
    end
  end
end
