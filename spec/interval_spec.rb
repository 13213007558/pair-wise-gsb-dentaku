require 'dentaku'
require 'spec_helper'

RSpec.describe Dentaku::Interval do
  def interval(low, high)
    described_class.new(Rational(low), Rational(high))
  end

  describe 'arithmetic' do
    it 'adds and subtracts endpoint-wise' do
      expect(interval(1, 2).add(interval(3, 5)).to_a).to eq [4, 7]
      expect(interval(1, 2).sub(interval(3, 5)).to_a).to eq [-4, -1]
    end

    it 'does not assume repeated variables are independent' do
      x = interval(0, 1)
      expect(x.sub(x).to_a).to eq [-1, 1]
    end

    it 'spans all four corner products' do
      x = interval(0, 1)
      one_minus_x = interval(1, 1).sub(x)
      expect(x.mul(one_minus_x).to_a).to eq [0, 1]
    end

    it 'keeps 0 times an unbounded interval finite' do
      expect(described_class::ZERO.mul(described_class::UNIVERSE)).to eq described_class::ZERO
    end

    it 'shifts and scales unbounded endpoints soundly' do
      universe = described_class::UNIVERSE
      expect(universe.add(interval(1, 1))).to eq universe
      expect(universe.sub(interval(1, 1))).to eq universe
      expect(universe.mul(interval(-2, -2))).to eq universe
      half_line = described_class.new(0, described_class::POSITIVE_INFINITY)
      expect(interval(0, 1).sub(half_line))
        .to eq described_class.new(described_class::NEGATIVE_INFINITY, 1)
    end
  end

  describe 'division' do
    it 'raises for an exact zero divisor' do
      expect { interval(1, 1).div(interval(0, 0)) }.to raise_error(Dentaku::ZeroDivisionError)
    end

    it 'distinguishes a straddling-zero divisor (unbounded image, undefined point)' do
      image, undefined = interval(-1, 2).div(interval(-1, 1))
      expect(image).to eq described_class::UNIVERSE
      expect(undefined).to eq [0]
    end

    it 'reports a half-open image when the divisor touches zero' do
      image, undefined = interval(1, 2).div(interval(0, 1))
      expect(image.to_a).to eq [1, Float::INFINITY]
      expect(undefined).to eq [0]
    end

    it 'stays finite when the divisor interval avoids zero' do
      image, undefined = interval(1, 2).div(interval(-2, -1))
      expect(image.to_a).to eq [-2, Rational(-1, 2)]
      expect(undefined).to eq []
    end
  end

  describe 'integer powers' do
    it 'wraps even powers across zero with zero on the inside' do
      image, = interval(-2, 3).ipow(2)
      expect(image.to_a).to eq [0, 9]
    end

    it 'preserves sign for odd powers' do
      image, = interval(-3, -2).ipow(3)
      expect(image.to_a).to eq [-27, -8]
    end

    it 'marks zero undefined for negative exponents' do
      image, undefined = interval(-2, 3).ipow(-1)
      expect(image).to eq described_class::UNIVERSE
      expect(undefined).to eq [0]
    end
  end

  describe 'abs' do
    it 'handles positive, negative and zero-crossing intervals' do
      expect(interval(2, 5).abs.to_a).to eq [2, 5]
      expect(interval(-5, -2).abs.to_a).to eq [2, 5]
      expect(interval(-2, 3).abs.to_a).to eq [0, 3]
    end
  end

  describe 'outward rounding' do
    it 'rounds the low endpoint down and the high endpoint up' do
      rounded, moved = interval(Rational(1, 3), Rational(2, 3)).round_outward(3)
      expect(moved).to be true
      expect(rounded.low).to be <= Rational(1, 3)
      expect(rounded.high).to be >= Rational(2, 3)
      expect(rounded.to_a.map { |value| format('%.3f', value) }).to eq ['0.333', '0.667']
    end

    it 'leaves integral endpoints untouched' do
      rounded, moved = interval(-2, 2).round_outward(3)
      expect(moved).to be false
      expect(rounded.to_a).to eq [-2, 2]
    end
  end

  describe 'sample_grid' do
    it 'enumerates a rational grid including both endpoints' do
      expect(interval(0, 1).sample_grid(4)).to eq [0, Rational(1, 4), Rational(1, 2), Rational(3, 4), 1]
    end
  end
end
