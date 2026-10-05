require 'spec_helper'
require 'dentaku'
require 'dentaku/calculator'
require 'dentaku/print_visitor'

describe Dentaku::Calculator do
  describe 'expression-defined functions' do
    let(:calculator) { described_class.new }

    describe 'declaration' do
      it 'evaluates a function declared with signature and body' do
        calculator.define_function('margin(revenue, cost)', '(revenue - cost) / revenue')
        expect(calculator.evaluate!('margin(100, 40)')).to eq(BigDecimal('0.6'))
      end

      it 'evaluates a function declared as a single string' do
        calculator.define_function('margin(revenue, cost) = (revenue - cost) / revenue')
        expect(calculator.evaluate!('margin(200, 50)')).to eq(BigDecimal('0.75'))
      end

      it 'composes with other formulas and run-time variables' do
        calculator.define_function('margin(revenue, cost)', '(revenue - cost) / revenue')
        expect(calculator.evaluate!('margin(r, c) * 100', r: 250, c: 50)).to eq(80)
      end

      it 'returns an introspectable definition' do
        definition = calculator.define_function('margin(revenue, cost)', '(revenue - cost) / revenue')

        expect(definition.name).to eq('margin')
        expect(definition.version).to eq(1)
        expect(definition.label).to eq('margin(v1)')
        expect(definition.parameters.map(&:name)).to eq(%w[revenue cost])
        expect(definition.signature_source).to eq('margin(revenue, cost)')
        expect(calculator.function_definition(:margin)).to eq(definition)
        expect(calculator.function_definition(:nonexistent)).to be_nil
      end
    end

    describe 'parameters and defaults' do
      it 'lets a default reference an earlier parameter' do
        calculator.define_function('scale(value, factor = value * 2)', 'value + factor')

        expect(calculator.evaluate!('scale(3)')).to eq(9)
        expect(calculator.evaluate!('scale(3, 10)')).to eq(13)
      end

      it 'lets defaults chain and reference constants' do
        calculator.define_function('price(qty, unit = 10, tax = qty * unit * rate)',
                                     'qty * unit + tax',
                                     constants: { rate: 0.1 })

        expect(calculator.evaluate!('price(2)')).to eq(22)
        expect(calculator.evaluate!('price(2, 5)')).to eq(11)
      end

      it 'supports zero-argument functions' do
        calculator.define_function('rate()', '0.1')
        expect(calculator.evaluate!('rate()')).to eq(BigDecimal('0.1'))
      end

      it 'enforces arity when the call is parsed' do
        calculator.define_function('margin(revenue, cost)', '(revenue - cost) / revenue')

        expect { calculator.evaluate!('margin(1)') }.to raise_error(Dentaku::ParseError, /too few/)
        expect { calculator.evaluate!('margin(1, 2, 3)') }.to raise_error(Dentaku::ParseError, /too many/)
      end
    end

    describe 'constants' do
      it 'captures constants at definition time' do
        calculator.define_function('add_fee(price)', 'price + fee', constants: { fee: 5 })
        expect(calculator.evaluate!('add_fee(10)')).to eq(15)
      end

      it 'does not let caller-provided variables swap a constant' do
        calculator.define_function('add_fee(price)', 'price + fee', constants: { fee: 5 })

        expect(calculator.evaluate!('add_fee(10)', fee: 999)).to eq(15)

        calculator.store(fee: 999) do
          expect(calculator.evaluate!('add_fee(10)')).to eq(15)
        end
      end

      it 'lets parameters shadow constants' do
        calculator.define_function('shadow(x)', 'x + 1', constants: { x: 100 })
        expect(calculator.evaluate!('shadow(1)')).to eq(2)
      end

      it 'rejects bodies that reference anything but parameters and constants' do
        expect { calculator.define_function('bad(x)', 'x + ghost') }
          .to raise_error(Dentaku::UnboundVariableError, /ghost/)
      end
    end

    describe 'function-to-function calls' do
      it 'calls other expression-defined functions' do
        calculator.define_function('net(revenue, cost)', 'revenue - cost')
        calculator.define_function('margin(revenue, cost)', 'net(revenue, cost) / revenue')

        expect(calculator.evaluate!('margin(100, 40)')).to eq(BigDecimal('0.6'))
      end

      it 'keeps the callee version captured when the caller was defined' do
        calculator.define_function('net(revenue, cost)', 'revenue - cost')
        calculator.define_function('margin(revenue, cost)', 'net(revenue, cost) / revenue')
        calculator.define_function('net(revenue, cost)', '0')

        expect(calculator.function_version(:net)).to eq(2)
        expect(calculator.evaluate!('margin(100, 40)')).to eq(BigDecimal('0.6'))
        expect(calculator.evaluate!('net(100, 40)')).to eq(0)
      end

      it 'supports direct recursion' do
        calculator.define_function('fact(n)', 'if(n <= 1, 1, n * fact(n - 1))')
        expect(calculator.evaluate!('fact(5)')).to eq(120)
      end

      it 'supports mutually recursive functions' do
        calculator.define_function('is_even(n)', 'if(n = 0, true, is_odd(n - 1))')
        calculator.define_function('is_odd(n)', 'if(n = 0, false, is_even(n - 1))')

        expect(calculator.evaluate!('is_even(10)')).to eq(true)
        expect(calculator.evaluate!('is_even(7)')).to eq(false)
        expect(calculator.evaluate!('is_odd(7)')).to eq(true)
      end

      it 'resolves forward references once the target is defined' do
        calculator.define_function('fwd(x)', 'notyet(x)')

        expect { calculator.evaluate!('fwd(1)') }
          .to raise_error(Dentaku::ParseError, /Undefined function notyet/)

        calculator.define_function('notyet(x)', 'x * 2')
        expect(calculator.evaluate!('fwd(21)')).to eq(42)
      end

      it 'checks arity of late-bound calls at call time' do
        calculator.define_function('caller_fn(x)', 'later(x, 1, 2)')
        calculator.define_function('later(a, b)', 'a + b')

        expect { calculator.evaluate!('caller_fn(1)') }
          .to raise_error(Dentaku::ArgumentError, /wrong number of arguments/)
      end
    end

    describe 'versioning' do
      it 'tracks the current version and pins compiled formulas to theirs' do
        calculator.define_function('rate()', '0.1')
        compiled = calculator.ast('rate() * 100')
        function_node = calculator.ast('rate()')

        calculator.define_function('rate()', '0.2')

        expect(calculator.function_version(:rate)).to eq(2)
        expect(calculator.function_definition(:rate).version).to eq(2)
        expect(function_node.class.definition.version).to eq(1)

        expect(calculator.evaluate!(compiled)).to eq(10)
        expect(calculator.evaluate!('rate() * 100')).to eq(20)
      end

      it 'returns nil version for unknown functions' do
        expect(calculator.function_version(:nope)).to be_nil
      end
    end

    describe 'budgets' do
      it 'bounds the call depth and reports the call chain' do
        calculator = described_class.new(max_function_call_depth: 5)
        calculator.define_function('loopf(n)', 'loopf(n + 1)')

        expect { calculator.evaluate!('loopf(1)') }
          .to raise_error(Dentaku::FunctionBudgetError) { |error|
            expect(error.reason).to eq(:depth)
            expect(error.limit).to eq(5)
            expect(error.call_chain).to eq(['loopf(v1)'] * 6)
            expect(error.message).to include('loopf(v1) -> loopf(v1)')
          }
        expect(calculator.memory).to be_empty
      end

      it 'bounds the total number of function invocations' do
        calculator = described_class.new(max_function_operations: 3)
        calculator.define_function('f(x)', 'g(x) + g(x)')
        calculator.define_function('g(x)', 'h(x) + h(x)')
        calculator.define_function('h(x)', 'x')

        expect { calculator.evaluate!('f(1)') }
          .to raise_error(Dentaku::FunctionBudgetError) { |error|
            expect(error.reason).to eq(:operations)
            expect(error.limit).to eq(3)
          }
      end

      it 'allows adjusting budgets after initialization' do
        calculator.max_function_call_depth = 3
        calculator.define_function('loopf(n)', 'loopf(n + 1)')

        expect { calculator.evaluate!('loopf(1)') }.to raise_error(Dentaku::FunctionBudgetError)
      end
    end

    describe 'error call chain' do
      it 'annotates errors with the chain of function calls' do
        calculator.define_function('outer(x)', 'inner(x) + 1')
        calculator.define_function('inner(x)', 'x / 0')

        expect { calculator.evaluate!('outer(1)') }
          .to raise_error(Dentaku::ZeroDivisionError) { |error|
            expect(error.call_chain).to eq(['outer(v1)', 'inner(v1)'])
            expect(error.message).to include('in outer(v1) -> inner(v1)')
          }
      end

      it 'returns nil from permissive evaluation when a call fails' do
        calculator.define_function('boom(x)', 'x / 0')
        expect(calculator.evaluate('boom(1)')).to be_nil
      end
    end

    describe 'memory isolation' do
      it 'does not leak parameters, constants or runtime state into memory' do
        calculator.define_function('add_fee(price)', 'price + fee', constants: { fee: 5 })
        calculator.evaluate!('add_fee(10)', temp: 1)

        expect(calculator.memory).to be_empty
      end

      it 'does not pollute memory when a call fails' do
        calculator.define_function('boom(x)', 'x / 0')
        calculator.store(keep: 1)

        expect { calculator.evaluate!('boom(1)', temp: 2) }
          .to raise_error(Dentaku::ZeroDivisionError)
        expect(calculator.memory).to eq('keep' => 1)
      end
    end

    describe 'definition validation' do
      it 'rejects malformed signatures' do
        expect { calculator.define_function('not a signature', '1') }
          .to raise_error(Dentaku::FunctionDefinitionError)
        expect { calculator.define_function('f(x)', '') }
          .to raise_error(Dentaku::FunctionDefinitionError, /missing body/)
      end

      it 'rejects duplicate parameters' do
        expect { calculator.define_function('dup(x, x)', 'x') }
          .to raise_error(Dentaku::FunctionDefinitionError, /duplicate/)
      end

      it 'rejects required parameters after defaulted ones' do
        expect { calculator.define_function('ord(a = 1, b)', 'a + b') }
          .to raise_error(Dentaku::FunctionDefinitionError, /follows a default/)
      end

      it 'rejects defaults referencing unknown names' do
        expect { calculator.define_function('d(x = y)', 'x') }
          .to raise_error(Dentaku::FunctionDefinitionError, /unknown/)
      end

      it 'rejects invalid constant names' do
        expect { calculator.define_function('c(x)', 'x', constants: { '1bad' => 1 }) }
          .to raise_error(Dentaku::FunctionDefinitionError, /constant/)
      end
    end

    describe 'dependencies' do
      it 'reports only the call-site arguments' do
        calculator.define_function('margin(revenue, cost)', '(revenue - cost) / revenue')

        expect(calculator.dependencies('margin(a, b)')).to match_array(%w[a b])
        expect(calculator.identifiers('margin(a, b) + c')).to match_array(%w[a b c])
      end
    end

    describe 'printing' do
      it 'renders calls with the function name' do
        calculator.define_function('margin(revenue, cost)', '(revenue - cost) / revenue')
        node = calculator.ast('margin(1, 2)')

        expect(Dentaku::PrintVisitor.new(node).to_s).to eq('MARGIN(1, 2)')
      end
    end
  end
end
