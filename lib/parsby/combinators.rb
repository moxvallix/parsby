class Parsby
  module Combinators
    extend self

    module ModuleMethods
      # The only reason to use this over regular def syntax is to get
      # automatic labels. For combinators defined with this, you'll get
      # labels that resemble the corresponding ruby expression.
      def define_combinator(name, wrap: true, &b)
        # Convert block to method. This is necessary not only to convert
        # the proc to something that'll verify arity, but also to get
        # super() in b to work.
        define_method(name, &b)
        m = if defined? instance_method
          instance_method name
        else
          # self is probably main
          method(name).unbind
        end

        # Lambda used to access private module method from instance method.
        inspectable_labels_lambda = lambda {|x| inspectable_labels(x) }

        define_method name do |*args, ignore: false, &b2|
          inspected_args = inspectable_labels_lambda.call(args).map(&:inspect)
          label = name.to_s
          label += "(#{inspected_args.join(", ")})" unless inspected_args.empty?
          # Wrap in new parser so we don't overwrite another automatic
          # label.
          p = m.bind(self).call(*args, &b2)
          if wrap
            Parsby.new(label, ignore) {|c| p.parse c }
          else
            p.ignore = ignore
            p % label
          end
        end
      end

      private

      # Returns an object whose #inspect representation is exactly as given
      # in the argument string.
      def inspectable_as(s)
        Object.new.tap do |obj|
          obj.define_singleton_method :inspect do
            s
          end
        end
      end

      # Deeply traverses arrays and hashes changing each Parsby object to
      # another object that returns their label on #inspect. The point of
      # this is to be able to inspect the result and get something
      # resembling the original combinator expression. Instead of writing
      # this method, I could also just have redefined #inspect on Parsby to
      # return the label, but I like ruby's default #inspect in general.
      def inspectable_labels(arg)
        case arg
        when Parsby
          inspectable_as arg.label
        when Array # for methods like group() that accept arguments spliced or not
          arg.map(&method(:inspectable_labels))
        when Hash # for key arguments
          arg.map {|k, v| [k, inspectable_labels(v)] }.to_h
        else
          arg
        end
      end

      def included(base)
        base.extend ModuleMethods
      end
    end

    extend ModuleMethods

    # Parses the string as literally provided.
    define_combinator :lit, wrap: false do |e, case_sensitive: true|
      Parsby.new(e.inspect) { |c|
        a = c.bio.read e.length
        if case_sensitive ? a == e : a.to_s.downcase == e.downcase
          a
        else
          raise ExpectationFailed.new c
        end
      }
    end

    define_combinator :ilit do |e|
      lit e, case_sensitive: false
    end

    # Same as <tt>p * n</tt>
    define_combinator :count do |n, p|
      p * n % "count(#{n}, #{p.label})"
    end

    # Uses =~ for matching. Only compares one char.
    define_combinator :char_matching, wrap: false do |r|
      Parsby.new r.inspect do |c|
        char = any_char.parse c
        unless char =~ r
          raise ExpectationFailed.new c
        end
        char
      end
    end

    # Parses a decimal number as matched by \d+.
    define_combinator :decimal do
      many_1(decimal_digit).fmap {|ds| ds.join.to_i }
    end

    # This is taken from the Json subparser for numbers.
    define_combinator :decimal_fraction do 
      sign = lit("-") | lit("+")
      group(
        optional(sign),
        decimal,
        optional(group(
          lit("."),
          decimal,
        )),
        optional(group(
          ilit("e"),
          optional(sign),
          decimal,
        )),
      ).fmap do |(sign, whole, (_, fractional), (_, exponent_sign, exponent))|
        n = whole
        n += fractional.to_f / 10 ** fractional.to_s.length if fractional
        n *= -1 if sign == "-"
        if exponent
          e = exponent
          e *= -1 if exponent_sign == "-"
          n *= 10 ** e
        end
        n
      end
    end

    # Parses single digit in range 0-9. Returns string, not number.
    define_combinator :decimal_digit do
      char_matching /[0-9]/
    end

    # Parses single hex digit. Optional argument lettercase can be one of
    # :insensitive, :upper, or :lower.
    define_combinator :hex_digit do |lettercase = :insensitive|
      decimal_digit | case lettercase
      when :insensitive
        char_matching /[a-fA-F]/
      when :upper
        char_matching /[A-F]/
      when :lower
        char_matching /[a-f]/
      else
        raise ArgumentError.new(
          "#{lettercase.inspect}: unrecognized; argument should be one of " \
          ":insensitive, :upper, or :lower"
        )
      end
    end

    # Parser that always fails without consuming input. We use it for at
    # least <tt>choice</tt>, for when it's supplied an empty list. It
    # corresponds with mzero in Haskell's Parsec.
    define_combinator :unparseable, wrap: false do
      Parsby.new {|c| raise ExpectationFailed.new c }
    end

    # Tries each provided parser until one succeeds. Providing an empty
    # list causes parser to always fail, like how [].any? is false.
    define_combinator :choice, wrap: false do |*ps|
      ps = ps.flatten

      splicer.start do |m|
        ps.reduce(unparseable) do |a, p|
          a | m.end(p)
        end
      end
    end

    def splicer
      Parsby::Splicer
    end

    # Parses a single char from the char options provided as string and
    # range arguments optionally arbitrarily nested in arrays.
    #
    #   join(many(char_in('a'..'z', 0..9))).parse "foo23 bar"
    #   #=> "foo23"
    #
    #   char_options = ['a'..'z', "!@#$%^"]
    #   join(many(char_in(0..9, char_options))).parse "foo23!@ bar"
    #   #=> "foo23!@"
    #
    define_combinator :char_in do |*strings|
      string = strings
        .flatten
        .map do |s|
          if s.is_a?(Range)
            s.to_a.join
          else
            s
          end
        end
        .join

      ~splicer.start do
        Parsby.new do |c|
          char = any_char.parse c
          unless string.chars.include? char
            raise ExpectationFailed.new c
          end
          char
        end
      end
    end

    # Parses string of 0 or more continuous whitespace characters (" ",
    # "\t", "\n", "\r")
    define_combinator :whitespace do
      whitespace_1 | pure("")
    end

    alias_method :ws, :whitespace

    # Parses string of 1 or more continuous whitespace characters (" ",
    # "\t", "\n", "\r")
    define_combinator :whitespace_1 do
      ~splicer.start { join(many_1(char_in(" \t\n\r"))) }
    end

    alias_method :ws_1, :whitespace_1

    # Expects p to be surrounded by optional whitespace.
    define_combinator :spaced do |p|
      ~splicer.start {|m| ws > m.end(p) < ws }
    end

    # Convinient substitute of <tt>left > p < right</tt> for when
    # <tt>p</tt> is large to write.
    define_combinator :between do |left, right, p|
      left > p < right
    end

    # Turns parser into one that doesn't consume input.
    define_combinator :peek, wrap: false do |p|
      Parsby.new {|c| p.peek c }
    end

    # Parser that returns provided value without consuming any input.
    define_combinator :pure, wrap: false do |x|
      Parsby.new { x }
    end

    # Delays construction of parser until parsing-time. This allows one to
    # construct recursive parsers, which would otherwise result in a
    # stack-overflow in construction-time.
    define_combinator :lazy, wrap: false do |&b|
      # Can't have a better label, because we can't know what the parser is
      # until parsing time.
      Parsby.new {|c| b.call.parse c }
    end

    # Make a recursive parser. Block shall take an argument and return a
    # parser. The block's argument is the parser it returns.
    #
    # Example:
    #
    #   recursive {|p|
    #     single(lit("(") > optional(p) < lit(")"))
    #   }.parse "((()))"
    #   #=> [[[nil]]]
    #
    # This is analogous to Haskell's fix function.
    define_combinator :recursive, wrap: false do |&b|
      p = lazy { b.call p }
    end

    # Similar to Enumerable's #reduce. Takes parser as argument, passes the
    # parsing result to the block, parses using result of block, the result
    # of the parse is passed again to the block, and so on until the
    # returned parser fails. Returns the last result before failure.
    #
    # The only way for this parser to fail is if the initial parser passed
    # as argument fails.
    #
    # This combinator is meant to make shift-reduce parsers for LR
    # grammars.
    define_combinator :reduce, wrap: false do |init, &b|
      init.then do |accum|
        Parsby.new do |c|
          begin
            accum = b.call(accum).parse(c) while true
          rescue ExpectationFailed
            accum
          end
        end
      end
    end

    define_combinator :fmap do |p, &b|
      p.fmap(&b)
    end

    # Results in empty array without consuming input. This is meant to be
    # used to start off use of <<.
    #
    # Example:
    #
    #   (empty << string("foo") << string("bar")).parse "foobar"
    #   => ["foo", "bar"]
    define_combinator :empty do
      pure []
    end

    # Groups results into an array.
    define_combinator :group do |*ps|
      ps = ps.flatten
      (~splicer.start { |m|
        ps.reduce(empty) do |a, p|
          a << m.end(p)
        end
      }).fmap { |result| result.size == 1 ? result.first : result }
    end

    # Wraps result in a list. This is to be able to do
    #
    #   single(...) + many(...)
    define_combinator :single do |p|
      p.fmap {|x| [x]}
    end

    # Runs parser until it fails and returns an array of the results. Because
    # it can return an empty array, this parser can never fail.
    define_combinator :many, wrap: false do |p|
      Parsby.new do |c|
        rs = []
        while true
          break if c.bio.eof?
          begin
            rs << p.parse(c)
          rescue Error
            break
          end
        end
        rs
      end
    end

    # Same as many, but fails if it can't match even once.
    define_combinator :many_1 do |p|
      single(p) + many(p)
    end

    # Like many, but accepts another parser for separators. It returns a list
    # of the results of the first argument. Returns an empty list if it
    # didn't match even once, so it never fails.
    define_combinator :sep_by do |s, p|
      sep_by_1(s, p) | empty
    end

    # Like sep_by, but fails if it can't match even once.
    define_combinator :sep_by_1 do |s, p|
      single(p) + many(s > p)
    end

    # Join the Array result of p.
    define_combinator :join do |p|
      p.fmap(&:join)
    end

    # Tries the given parser and returns nil if it fails.
    define_combinator :optional do |p|
      p | pure(nil)
    end

    # Parses any char. Only fails on EOF.
    define_combinator :any_char, wrap: false do
      Parsby.new do |c|
        if c.bio.eof?
          raise ExpectationFailed.new c
        end
        c.bio.read 1
      end
    end

    # Matches EOF, fails otherwise. Returns nil.
    define_combinator :eof, wrap: false do
      Parsby.new :eof do |c|
        unless c.bio.eof?
          raise ExpectationFailed.new c
        end
      end
    end

    # Takes a block which can run multiple parsers
    # and use control flow to adapt itself.
    define_combinator :coroutine do |&block|
      Parsby.new do |target|

        parse = Proc.new do |parsby|
          parsby.parser.call target
        end

        block.call(parse)
      end
    end

    # Matches a regular expression
    define_combinator :regex do |regex|
      Parsby.new :regex do |target|
        position = target.bio.pos
        target_string = target.bio.read

        unless target_string.match?(regex)
          raise ExpectationFailed.new target
        end

        match = target_string.match(regex).to_s
        target.bio.restore_to(position + match.length)

        match
      end
    end
  end
end
