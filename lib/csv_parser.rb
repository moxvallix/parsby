class CsvParser < Parsby
  def self.parse(source)
    csv.parse source
  end

  def self.csv
    many(record) < eof
  end

  def self.record
    sep_by(cell, string(",")) < eol
  end

  def self.cell
    quoted_cell | non_quoted_cell
  end

  def self.quoted_cell
    non_quote = many(any_char.failing(string('"'))).fmap(&:join)
    inner = sep_by(non_quote, string('""')).fmap {|r| r.join '"' }
    string('"') > inner < string('"')
  end

  def self.eol
    string("\r\n") | string("\n")
  end

  def self.non_quoted_cell
    many(any_char.failing(string(",") | string("\"") | eol)).fmap(&:join)
  end
end