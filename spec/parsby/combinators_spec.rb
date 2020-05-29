RSpec.describe Parsby::Combinators do
  include Parsby::Combinators

  describe :many do
    it "applies parser repeatedly and returns a list of the results" do
      expect(many(string("foo")).parse "foofoofoo")
        .to eq ["foo", "foo", "foo"]
    end

    it "returns empty list when parser couldn't be applied" do
      expect(many(string("bar")).parse "foofoofoo")
        .to eq []
    end
  end

  describe :any_char do
    it "raises exception on EOF" do
      expect { any_char.parse "" }
        .to raise_error Parsby::ExpectationFailed
    end
  end

  describe :decimal do
    it "parses decimal numbers" do
      expect(decimal.parse("123")).to eq 123
    end

    it "does not accept anything other than sign-less positive decimal integers" do
      expect(decimal.parse("123.45")).to eq 123
      expect { decimal.parse("-123") }
        .to raise_error Parsby::ExpectationFailed
      expect { decimal.parse("+123") }
        .to raise_error Parsby::ExpectationFailed
    end

    it "expects at least one decimal digit" do
      expect { decimal.parse("foo") }
        .to raise_error Parsby::ExpectationFailed
    end
  end

  describe :string do
    it "parses the string provided" do
      expect(string("foo").parse("foo")).to eq "foo"
    end
    
    # XXX: Backtracking should be handled BackedIO, but I've implemented
    # backtracking explicitely for #string (done before BackedIO). Because
    # of that, I thought this test would fail for restoring twice, but it
    # doesn't... It doesn't make a difference if #string restores on its
    # own or not, and I'd like to know why.
    it "backtracks properly on failure" do
      s = StringIO.new "barbaz"
      expect { string("foo").parse(s) }.to raise_error Parsby::ExpectationFailed
      expect(s.read).to eq "barbaz"

      s = StringIO.new "baz"
      expect { string("foobar").parse(s) }.to raise_error Parsby::ExpectationFailed
      expect(s.read).to eq "baz"
    end
  end
end