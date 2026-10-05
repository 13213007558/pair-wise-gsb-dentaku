require 'spec_helper'
require 'dentaku'
require 'dentaku/calculator'

describe Dentaku::Calculator do
  describe 'expression-defined functions' do
    let(:calculator) { described_class.new }

    describe 'definition forms' do
      it 'defines a function from a single declaration string' do
        definition = calculator.define_function('margin(revenue, cost) = (revenue - cost) / revenue')

        expect(definition).to be_a(Dentaku::FunctionDefinition)
        expect(definition.name).to eq('margin')
        expect(definition.params).to eq(%w[revenue cost])
        expect(definition.version).to eq(1)
        expect(calculator.evaluate!('margin(100, 40)')).to eq(0.6)
      end

      it 'defines a function from name, params and body' do
        calculator.define_function(:margin, [:revenue, :cost], '(revenue - cost) / revenue')

        expect(calculator.evaluate!('margin(revenue, 40)', revenue: 100)).to eq(0.6)
      end

      it 'is callable from other formulas' do
        calculator.define_function('margin(revenue, cost) = (revenue - cost) / revenue')

        expect(calculator.evaluate!('round(margin(100, 40) * 100, 1)')).to eq(60.0)
        expect(calculator.dependencies('margin(a, b) + c')).to contain_exactly('a', 'b', 'c')
      end

      it 'rejects a malformed declaration string' do
        expect { calculator.define_function('margin(revenue, cost)') }
          .to raise_error(Dentaku::ArgumentError)
        expect { calculator.define_function('= 1') }
          .to raise_error(Dentaku::ArgumentError)
      end
    end

    describe 'parameters and defaults' do
      it 'supports default values, including inline in the declaration' do
        calculator.define_function('pay(price, qty = 1) = price * qty')

        expect(calculator.evaluate!('pay(10)')).to eq(10)
        expect(calculator.evaluate!('pay(10, 3)')).to eq(30)
      end

      it 'lets a default reference the parameters declared before it' do
        calculator.define_function(:pay, [:price, :qty, :total], 'total',
                                   defaults: { qty: 1, total: 'price * qty' })

        expect(calculator.evaluate!('pay(10)')).to eq(10)
        expect(calculator.evaluate!('pay(10, 3)')).to eq(30)
        expect(calculator.evaluate!('pay(10, 3, 99)')).to eq(99)
      end

      it 'rejects a default that references a later parameter' do
        expect {
          calculator.define_function(:bad, [:a, :b], 'a + b', defaults: { a: 'b * 2' })
        }.to raise_error(Dentaku::ArgumentError, /earlier parameters/)
      end

      it 'rejects defaults for undeclared parameters and duplicate parameters' do
        expect {
          calculator.define_function(:bad, [:a], 'a', defaults: { b: 1 })
        }.to raise_error(Dentaku::ArgumentError, /non-parameters/)

        expect {
          calculator.define_function(:bad, [:a, :a], 'a')
        }.to raise_error(Dentaku::ArgumentError, /duplicate/)
      end

      it 'enforces arity at parse time' do
        calculator.define_function(:margin, [:revenue, :cost], '(revenue - cost) / revenue')

        expect { calculator.dependencies('margin(1)') }.to raise_error(Dentaku::ParseError)
        expect { calculator.dependencies('margin(1, 2, 3)') }.to raise_error(Dentaku::ParseError)
      end
    end

    describe 'scoping rules' do
      it 'captures constants at definition time' do
        calculator.define_function(:add_tax, [:price], 'price * (1 + tax_rate)',
                                   constants: { tax_rate: 0.1 })

        expect(calculator.evaluate!('add_tax(100)')).to be_within(0.0001).of(110)
      end

      it 'never lets caller variables steal definition-time constants' do
        calculator.define_function(:add_tax, [:price], 'price * (1 + tax_rate)',
                                   constants: { tax_rate: 0.1 })

        calculator.store('tax_rate', 0.9) do
          expect(calculator.evaluate!('add_tax(100)')).to be_within(0.0001).of(110)
        end
      end

      it 'lets parameters shadow same-named constants' do
        calculator.define_function(:scale, [:amount, :rate], 'amount * rate',
                                   defaults: { rate: 0.2 },
                                   constants: { rate: 0.9 })

        expect(calculator.evaluate!('scale(100)')).to be_within(0.0001).of(20)
        expect(calculator.evaluate!('scale(100, 0.5)')).to be_within(0.0001).of(50)
      end

      it 'does not leak caller variables with the same name as a parameter' do
        calculator.define_function(:double, [:x], 'x * 2')

        calculator.store('x', 1000) do
          expect(calculator.evaluate!('double(3)')).to eq(6)
        end
      end

      it 'rejects bodies that reference anything but params and constants' do
        expect {
          calculator.define_function(:bad, [:x], 'x + global_rate')
        }.to raise_error(Dentaku::ArgumentError, /unknown names: global_rate/)
      end

      it 'leaves no trace in the registry after a failed definition' do
        expect {
          calculator.define_function('broken(x) = not_yet_defined(x) + global_rate')
        }.to raise_error(Dentaku::ArgumentError)

        expect(calculator.function_version(:broken)).to be_nil
        expect { calculator.dependencies('not_yet_defined(1)') }
          .to raise_error(Dentaku::ParseError, /Undefined function/)
      end
    end

    describe 'function composition and recursion' do
      it 'lets functions call other functions' do
        calculator.define_function('margin(revenue, cost) = (revenue - cost) / revenue')
        calculator.define_function('margin_pct(revenue, cost) = margin(revenue, cost) * 100')

        expect(calculator.evaluate!('margin_pct(100, 40)')).to be_within(0.0001).of(60)
      end

      it 'supports direct recursion' do
        calculator.define_function('fact(n) = if(n <= 1, 1, n * fact(n - 1))')

        expect(calculator.evaluate!('fact(5)')).to eq(120)
      end

      it 'binds mutually recursive functions defined in either order' do
        calculator.define_function('is_even(n) = if(n = 0, true, is_odd(n - 1))')
        calculator.define_function('is_odd(n) = if(n = 0, false, is_even(n - 1))')

        expect(calculator.evaluate!('is_even(10)')).to eq(true)
        expect(calculator.evaluate!('is_even(7)')).to eq(false)
        expect(calculator.evaluate!('is_odd(7)')).to eq(true)
      end

      it 'raises UndefinedFunctionError when a forward reference is never defined' do
        calculator.define_function('is_even(n) = if(n = 0, true, is_odd(n - 1))')

        expect { calculator.evaluate!('is_even(2)') }
          .to raise_error(Dentaku::UndefinedFunctionError, /is_odd/)
      end
    end

    describe 'versioning' do
      it 'tracks the current version per name' do
        calculator.define_function(:dbl, [:x], 'x * 2')
        expect(calculator.function_version(:dbl)).to eq(1)

        calculator.define_function(:dbl, [:x], 'x * 3')
        expect(calculator.function_version(:dbl)).to eq(2)
        expect(calculator.function_definition(:dbl).body).to eq('x * 3')
      end

      it 'keeps previously compiled formulas pinned to their version' do
        calculator.define_function(:dbl, [:x], 'x * 2')
        compiled = calculator.ast('dbl(21)')
        expect(compiled.class.definition.version).to eq(1)

        calculator.define_function(:dbl, [:x], 'x * 3')

        expect(calculator.evaluate!(compiled)).to eq(42)
        expect(compiled.class.definition.version).to eq(1)
        expect(calculator.evaluate!('dbl(21)')).to eq(63)
        expect(calculator.ast('dbl(21)').class.definition.version).to eq(2)
      end

      it 'binds a recursive call to the version that defines it' do
        calculator.define_function('countdown(n) = if(n <= 0, 0, 1 + countdown(n - 1))')
        calculator.define_function('countdown(n) = if(n <= 0, 100, 1 + countdown(n - 1))')

        # the v2 body recurses into v2; v1 remains independently callable
        expect(calculator.evaluate!('countdown(3)')).to eq(103)
      end
    end

    describe 'budgets' do
      it 'bounds call depth and reports the call chain' do
        calculator.define_function('boom(x) = boom(x + 1)')

        error = nil
        begin
          calculator.evaluate!('boom(1)')
        rescue Dentaku::FunctionCallBudgetError => e
          error = e
        end

        expect(error).not_to be_nil
        expect(error.reason).to eq(:depth)
        expect(error.limit).to eq(Dentaku::CallBudget::DEFAULT_MAX_DEPTH)
        expect(error.call_chain.length).to eq(Dentaku::CallBudget::DEFAULT_MAX_DEPTH + 1)
        expect(error.call_chain.first).to eq('boom(x) v1')
        expect(error.message).to include('boom(x) v1 -> boom(x) v1')
      end

      it 'bounds total operations across the whole call graph' do
        limited = described_class.new(max_function_operations: 50)
        limited.define_function('boom(x) = boom(x + 1)')

        expect { limited.evaluate!('boom(1)') }
          .to raise_error(Dentaku::FunctionCallBudgetError) { |e|
            expect(e.reason).to eq(:operations)
            expect(e.limit).to eq(50)
          }
      end

      it 'counts operations across mutually recursive calls' do
        limited = described_class.new(max_function_depth: 1_000, max_function_operations: 10)
        limited.define_function('ping(n) = if(n <= 0, 0, pong(n - 1))')
        limited.define_function('pong(n) = if(n <= 0, 0, ping(n - 1))')

        expect { limited.evaluate!('ping(100)') }
          .to raise_error(Dentaku::FunctionCallBudgetError) { |e|
            expect(e.reason).to eq(:operations)
            expect(e.call_chain.grep(/ping/).length).to be > 0
            expect(e.call_chain.grep(/pong/).length).to be > 0
          }
      end

      it 'resets the budget between evaluations' do
        calculator.define_function('fact(n) = if(n <= 1, 1, n * fact(n - 1))')

        expect(calculator.evaluate!('fact(20)')).to eq(2_432_902_008_176_640_000)
        expect(calculator.evaluate!('fact(20)')).to eq(2_432_902_008_176_640_000)
      end
    end

    describe 'error reporting' do
      it 'attaches the function call chain to errors raised inside a body' do
        calculator.define_function('inner(x) = 1 / x')
        calculator.define_function('outer(x) = inner(x) + 1')

        error = nil
        begin
          calculator.evaluate!('outer(0)')
        rescue Dentaku::Error => e
          error = e
        end

        expect(error).to be_a(Dentaku::ZeroDivisionError)
        expect(error.call_chain).to eq(['outer(x) v1', 'inner(x) v1'])
        expect(error.message).to include('outer(x) v1 -> inner(x) v1')
      end

      it 'reports the chain only once for nested failures' do
        calculator.define_function('inner(x) = 1 / x')
        calculator.define_function('middle(x) = inner(x)')
        calculator.define_function('outer(x) = middle(x)')

        begin
          calculator.evaluate!('outer(0)')
        rescue Dentaku::Error => e
          expect(e.message.scan('function call chain').length).to eq(1)
        end
      end
    end

    describe 'memory isolation' do
      it 'does not pollute calculator memory on failed calls' do
        calculator.define_function('failing(x) = 1 / x')

        expect { calculator.evaluate!('failing(0)') }.to raise_error(Dentaku::ZeroDivisionError)
        expect(calculator.memory).to eq({})
      end

      it 'does not pollute calculator memory on successful calls' do
        calculator.define_function('pay(price, qty = 1, total = price * qty) = total')

        calculator.evaluate!('pay(10, 3)')
        expect(calculator.memory).to eq({})
      end

      it 'does not leak budget state into memory' do
        calculator.define_function('boom(x) = boom(x + 1)')

        expect { calculator.evaluate!('boom(1)') }
          .to raise_error(Dentaku::FunctionCallBudgetError)
        expect(calculator.memory).to eq({})
      end
    end
  end
end
