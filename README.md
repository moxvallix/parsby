# Parsby

Parser combinator library for Ruby, based on Haskell's Parsec.

 - [Installation](#installation)
 - [Introduction](#introduction)
 - [`reduce` combinator](#reduce-combinator)
 - [Comparing with Haskell's Parsec](#comparing-with-haskells-parsec)

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'parsby'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install parsby

## Introduction

If you're already familiar with this type of library, you might prefer to
skip to [Comparing with Haskell's Parsec](#comparing-with-haskells-parsec),
and/or check-out the example parsers:

 - [CSV (RFC 4180 compliant)](lib/parsby/example/csv_parser.rb)
 - [JSON](lib/parsby/example/json_parser.rb)
 - [Lisp](lib/parsby/example/lisp_parser.rb)
 - [Arithmetic](lib/parsby/example/arithmetic_parser.rb)

Carrying on, this is a library used to define parsers by declaratively
describing a syntax using what's commonly referred to as combinators.
Parser combinators are functions that take parsers as inputs and/or return
parsers as outputs, i.e. they *combine* parsers into new parsers.

As an example, `between` is a combinator with 3 parameters: a parser for
what's to the left, one for what's to the right, and lastly one for what's
in-between them, and it returns a parser that, after parsing, returns the
result of the in-between parser:

```ruby
between(lit("<"), lit(">"), lit("foo")).parse "<foo>"
#=> "foo"
```

`lit` is a combinator that takes a string and returns a parser for that
string.

For example, here is the parser for a [JSON array][]:

```ruby
def array
  between(lit("["), ws > lit("]"), sep_by(lit(","), spaced(lazy { value })))
end
```

Here's a [JSON number][]:

```ruby
def number 
  sign = lit("-") | lit("+")
  group(
    optional(sign),
    decimal,
    optional(group(
      lit("."),
      decimal,
    )),
    optional(group(
      lit("e") | lit("E"),
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
```

[JSON array]: lib/parsby/example/json_parser.rb
[JSON number]: lib/parsby/example/json_parser.rb

## `Parsby.new`

Now, normally one ought to be able to define parsers using just
combinators, but there are times when one might need more control. For
those times, the most raw way to define a parser is using `Parsby.new`.

Let's look at a slightly simplified pre-existing use:

```ruby
def lit(e, case_sensitive: true)
  Parsby.new(e.inspect) do |c|
    a = c.bio.read e.length
    if case_sensitive ? a == e : a.to_s.downcase == e.downcase
      a
    else
      raise ExpectationFailed.new c
    end
  end
end
```

That's the `lit` combinator mentioned before. It takes a string argument
for what it `e`xpects to parse, and returns what was `a`ctually parsed if
it matches the expectation.

## Defining combinators

If you look at the examples in this source, you'll notice that all combinators are defined with `define_combinator`. Strictly speaking, it's not necessary to use that to define combinators. You can do it with variable assignment or `def` syntax. Nevertheless, `define_combinator` is preferred because it automates the assignment of a label to the combinator. Consider these examples:

```ruby
define_combinator :between do |left, right, p|
  left > p < right
end

between(lit("<"), lit(">"), lit("foo")).label
#=> 'between(lit("<"), lit(">"), lit("foo"))'
```

If we use `def` instead of `define_combinator`, then the label would be
that assigned by the outermost combinator. In the following case, it would
be that assigned by `<`.

```ruby
def between(left, right, p)
  left > p < right
end

between(lit("<"), lit(">"), lit("foo")).label
=> '((lit("<") > lit("foo")) < lit(">"))'
```

If we're to wrap that parser in a new one, then the label would be simply
unknown.

```ruby
def between(left, right, p)
  Parsby.new {|c| (left > p < right).parse c }
end

between(lit("<"), lit(">"), lit("foo")).label.to_s
=> "<unknown>"
```

## `ExpectationFailed`

Here's an example of an error, when parsing fails:

```
pry(main)> Parsby::Example::LispParser.sexp.parse "(foo (foo bar) 2.3 . . nil)"     
Parsby::ExpectationFailed: line 1:
  (foo `(foo ,bar) 2.3 . . nil)
                         |           * failure: char_in("([")
                         |           * failure: list
                         |           * failure: choice(abbrev, atom, list)
                         |           * failure: sexp
                       V            *| success: lit(".")
                   \-/             *|| success: sexp
       \---------/                *||| success: sexp
   \-/                           *|||| success: sexp
  V                             *||||| success: char_in("([")
                                \\\\\|
  |                                  * failure: list
  |                                  * failure: choice(abbrev, atom, list)
  |                                  * failure: sexp
```

It might be worth mentioning that when debugging a parser from an
`ExpectationFailed` error, the backtrace isn't really useful. That's
because the backtrace points to the code involved in parsing, not the code
involved in constructing the parsers, which succeeded, but is where the
problem typically lies. The tree-looking exception message above is meant
to somewhat substitute the utility of the backtrace in these cases.

Relating to that, the right-most text are the labels of the corresponding
parsers. I find that labels that resemble the source code are quite useful,
just like the snippets of code that appear right-most in backtraces. It's
because of this that I consider the use of `define_combinator` more
preferable than using `def` and explicitely assigning labels.

## `splicer` combinator

As displayed by the exception message above, Parsby manages a tree
structure representing parsers and their subparsers, with the information
of where a particular parser began parsing, where it ended, whether it
succeeded or failed, and the label of the parser.

If you look at the source of the example lisp parser, you might note that
there are a lot more parsers in between those shown in the graph. `sexp` is
not a direct child of `list`, for example, despite it appearing as so.
There are at least 6 ancestors/descendant parsers between `list` and
`sexp`. It'd be very much pointless to show them all. They convey little
additional information and their labels are very verbose. The reason why
they don't appear is because the `splicer` combinator is used to make the
tree look a little cleaner.

The name comes from JS's `Array.prototype.splice`, to which you can give a
starting position, and a count specifying the end, and it'll remove the
specified elements from an Array. We use `splicer` likewise, only it works
on parse trees. To show an example, here's a simplified definition of
`choice`:

```ruby
define_combinator :choice do |*ps|
  ps = ps.flatten

  ps.reduce(unparseable) do |a, p|
    a | p
  end
end
```

## Parsing from a string, a file, a pipe, a socket, ...

Any `IO` ought to work (unit tests currently have only checked pipes,
though). When you pass a string to `#parse` it wraps it with `StringIO`
before using it.

## Comparing with Haskell's Parsec

Although there's more to this library than its similarities with Parsec,
they are pretty similar:

```ruby
# Parsby                                 # Parsec
                                         #
foo.then {|x| bar x }                    # foo >>= \x -> bar x
                                         #
foo | bar                                # foo <|> bar
                                         #
foobar = Parsby.new do |c|               # foobar = do
  x = foo.parse c                        #   x <- foo
  bar(x).parse c                         #   bar x
end                                      #
                                         #
lit("(") > foo < lit(")")                # string "(" *> foo <* string ")"
                                         #
lit("5").fmap {|n| n.to_i + 1 }          # fmap (\n -> read n + 1) (string "5")
                                         #
group(                                   #
  w,                                     #
  group(x, y),                           #
  z,                                     #
).fmap do |(wr, (xr, yr), zr)|           #
  Foo.new(wr, Bar.new(xr, yr), zr)       # Foo <$> w <*> (Bar <$> x <*> y) <*> z
end                                      #
                                         #
                                         # -- Means the same, but this
                                         # -- raises an error in Haskell
                                         # -- because it requires an
                                         # -- infinite type [[[[...]]]]
recursive do |p|                         # fix $ \p ->
  between(lit("("), lit(")"),            #  between (string "(") (string ")") $
    single(p) | pure([])                 #    ((:[]) <$> p) <|> pure []
  end                                    #
end                                      #
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).
