require File.join(File.dirname(File.expand_path(__FILE__)), 'spec_helper.rb')

unless defined?(POSTGRES_DB)
  POSTGRES_URL = 'postgres://postgres:postgres@localhost:5432/reality_spec' unless defined? POSTGRES_URL
  POSTGRES_DB = Sequel.connect(ENV['SEQUEL_PG_SPEC_DB']||POSTGRES_URL)
end
INTEGRATION_DB = POSTGRES_DB unless defined?(INTEGRATION_DB)

# Automatic parameterization changes the SQL used, so don't check
# for expected SQL if it is being used.
if defined?(Sequel::Postgres::AutoParameterize)
  check_sqls = false
else
  check_sqls = true
end

def POSTGRES_DB.sqls
  (@sqls ||= [])
end
logger = Object.new
def logger.method_missing(m, msg)
  POSTGRES_DB.sqls << msg
end
POSTGRES_DB.loggers << logger

#POSTGRES_DB.instance_variable_set(:@server_version, 80200)
POSTGRES_DB.create_table! :test do
  text :name
  integer :value, :index => true
end
POSTGRES_DB.create_table! :test2 do
  text :name
  integer :value
end
POSTGRES_DB.create_table! :test3 do
  integer :value
  timestamp :time
end
POSTGRES_DB.create_table! :test4 do
  varchar :name, :size => 20
  bytea :value
end

describe "A PostgreSQL database" do
  before do
    @db = POSTGRES_DB
  end

  specify "should provide the server version" do
    @db.server_version.should > 70000
  end

  specify "should correctly parse the schema" do
    @db.schema(:test3, :reload=>true).should == [
      [:value, {:type=>:integer, :allow_null=>true, :default=>nil, :ruby_default=>nil, :db_type=>"integer", :primary_key=>false}],
      [:time, {:type=>:datetime, :allow_null=>true, :default=>nil, :ruby_default=>nil, :db_type=>"timestamp without time zone", :primary_key=>false}]
    ]
    @db.schema(:test4, :reload=>true).should == [
      [:name, {:type=>:string, :allow_null=>true, :default=>nil, :ruby_default=>nil, :db_type=>"character varying(20)", :primary_key=>false}],
      [:value, {:type=>:blob, :allow_null=>true, :default=>nil, :ruby_default=>nil, :db_type=>"bytea", :primary_key=>false}]
    ]
  end

  specify "should parse foreign keys for tables in a schema" do
    begin
      @db.create_table!(:public__testfk){primary_key :id; foreign_key :i, :public__testfk}
      @db.foreign_key_list(:public__testfk).should == [{:on_delete=>:no_action, :on_update=>:no_action, :columns=>[:i], :key=>[:id], :deferrable=>false, :table=>Sequel.qualify(:public, :testfk), :name=>:testfk_i_fkey}]
    ensure
      @db.drop_table(:public__testfk)
    end
  end
end

describe "A PostgreSQL dataset" do
  before do
    @d = POSTGRES_DB[:test]
    @d.delete # remove all records
    POSTGRES_DB.sqls.clear
  end

  specify "should quote columns and tables using double quotes if quoting identifiers" do
    @d.select(:name).sql.should == \
      'SELECT "name" FROM "test"'

    @d.select('COUNT(*)'.lit).sql.should == \
      'SELECT COUNT(*) FROM "test"'

    @d.select(:max.sql_function(:value)).sql.should == \
      'SELECT max("value") FROM "test"'

    @d.select(:NOW.sql_function).sql.should == \
    'SELECT NOW() FROM "test"'

    @d.select(:max.sql_function(:items__value)).sql.should == \
      'SELECT max("items"."value") FROM "test"'

    @d.order(:name.desc).sql.should == \
      'SELECT * FROM "test" ORDER BY "name" DESC'

    @d.select('test.name AS item_name'.lit).sql.should == \
      'SELECT test.name AS item_name FROM "test"'

    @d.select('"name"'.lit).sql.should == \
      'SELECT "name" FROM "test"'

    @d.select('max(test."name") AS "max_name"'.lit).sql.should == \
      'SELECT max(test."name") AS "max_name" FROM "test"'

    @d.insert_sql(:x => :y).should =~ \
      /\AINSERT INTO "test" \("x"\) VALUES \("y"\)( RETURNING NULL)?\z/

    if check_sqls
      @d.select(:test.sql_function(:abc, 'hello')).sql.should == \
        "SELECT test(\"abc\", 'hello') FROM \"test\""

      @d.select(:test.sql_function(:abc__def, 'hello')).sql.should == \
        "SELECT test(\"abc\".\"def\", 'hello') FROM \"test\""

      @d.select(:test.sql_function(:abc__def, 'hello').as(:x2)).sql.should == \
        "SELECT test(\"abc\".\"def\", 'hello') AS \"x2\" FROM \"test\""

      @d.insert_sql(:value => 333).should =~ \
        /\AINSERT INTO "test" \("value"\) VALUES \(333\)( RETURNING NULL)?\z/
    end
  end

  specify "should quote fields correctly when reversing the order if quoting identifiers" do
    @d.reverse_order(:name).sql.should == \
      'SELECT * FROM "test" ORDER BY "name" DESC'

    @d.reverse_order(:name.desc).sql.should == \
      'SELECT * FROM "test" ORDER BY "name" ASC'

    @d.reverse_order(:name, :test.desc).sql.should == \
      'SELECT * FROM "test" ORDER BY "name" DESC, "test" ASC'

    @d.reverse_order(:name.desc, :test).sql.should == \
      'SELECT * FROM "test" ORDER BY "name" ASC, "test" DESC'
  end

  specify "should support regexps" do
    @d << {:name => 'abc', :value => 1}
    @d << {:name => 'bcd', :value => 2}
    @d.filter(:name => /bc/).count.should == 2
    @d.filter(:name => /^bc/).count.should == 1
  end

  specify "should support NULLS FIRST and NULLS LAST" do
    @d << {:name => 'abc'}
    @d << {:name => 'bcd'}
    @d << {:name => 'bcd', :value => 2}
    @d.order(:value.asc(:nulls=>:first), :name).select_map(:name).should == %w[abc bcd bcd]
    @d.order(:value.asc(:nulls=>:last), :name).select_map(:name).should == %w[bcd abc bcd]
    @d.order(:value.asc(:nulls=>:first), :name).reverse.select_map(:name).should == %w[bcd bcd abc]
  end

  specify "#lock should lock tables and yield if a block is given" do
    @d.lock('EXCLUSIVE'){@d.insert(:name=>'a')}
  end

  specify "should support :using when altering a column's type" do
    begin
      @db = POSTGRES_DB
      @db.create_table!(:atest){Integer :t}
      @db[:atest].insert(1262304000)
      @db.alter_table(:atest){set_column_type :t, Time, :using=>'epoch'.cast(Time) + '1 second'.cast(:interval) * :t}
      @db[:atest].get(:t.extract(:year)).should == 2010
    ensure
      @db.drop_table?(:atest)
    end
  end

  specify "should support :using with a string when altering a column's type" do
    begin
      @db = POSTGRES_DB
      @db.create_table!(:atest){Integer :t}
      @db[:atest].insert(1262304000)
      @db.alter_table(:atest){set_column_type :t, Time, :using=>"'epoch'::timestamp + '1 second'::interval * t"}
      @db[:atest].get(:t.extract(:year)).should == 2010
    ensure
      @db.drop_table?(:atest)
    end
  end

  specify "should have #transaction support various types of synchronous options" do
    @db = POSTGRES_DB
    @db.transaction(:synchronous=>:on){}
    @db.transaction(:synchronous=>true){}
    @db.transaction(:synchronous=>:off){}
    @db.transaction(:synchronous=>false){}
    @db.sqls.grep(/synchronous/).should == ["SET LOCAL synchronous_commit = on", "SET LOCAL synchronous_commit = on", "SET LOCAL synchronous_commit = off", "SET LOCAL synchronous_commit = off"]

    @db.sqls.clear
    @db.transaction(:synchronous=>nil){}
    @db.sqls.should == ['BEGIN', 'COMMIT']

    if @db.server_version >= 90100
      @db.sqls.clear
      @db.transaction(:synchronous=>:local){}
      @db.sqls.grep(/synchronous/).should == ["SET LOCAL synchronous_commit = local"]

      if @db.server_version >= 90200
        @db.sqls.clear
        @db.transaction(:synchronous=>:remote_write){}
        @db.sqls.grep(/synchronous/).should == ["SET LOCAL synchronous_commit = remote_write"]
      end
    end
  end

  specify "should have #transaction support read only transactions" do
    @db = POSTGRES_DB
    @db.transaction(:read_only=>true){}
    @db.transaction(:read_only=>false){}
    @db.transaction(:isolation=>:serializable, :read_only=>true){}
    @db.transaction(:isolation=>:serializable, :read_only=>false){}
    @db.sqls.grep(/READ/).should == ["SET TRANSACTION READ ONLY", "SET TRANSACTION READ WRITE", "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE READ ONLY", "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE READ WRITE"]
  end

  specify "should have #transaction support deferrable transactions" do
    @db = POSTGRES_DB
    @db.transaction(:deferrable=>true){}
    @db.transaction(:deferrable=>false){}
    @db.transaction(:deferrable=>true, :read_only=>true){}
    @db.transaction(:deferrable=>false, :read_only=>false){}
    @db.transaction(:isolation=>:serializable, :deferrable=>true, :read_only=>true){}
    @db.transaction(:isolation=>:serializable, :deferrable=>false, :read_only=>false){}
    @db.sqls.grep(/DEF/).should == ["SET TRANSACTION DEFERRABLE", "SET TRANSACTION NOT DEFERRABLE", "SET TRANSACTION READ ONLY DEFERRABLE", "SET TRANSACTION READ WRITE NOT DEFERRABLE",  "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE READ ONLY DEFERRABLE", "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE READ WRITE NOT DEFERRABLE"]
  end if POSTGRES_DB.server_version >= 90100

  specify "should support creating indexes concurrently" do
    POSTGRES_DB.sqls.clear
    POSTGRES_DB.add_index :test, [:name, :value], :concurrently=>true
    POSTGRES_DB.sqls.should == ['CREATE INDEX CONCURRENTLY "test_name_value_index" ON "test" ("name", "value")'] if check_sqls
  end

  specify "should support dropping indexes only if they already exist" do
    POSTGRES_DB.add_index :test, [:name, :value], :name=>'tnv1'
    POSTGRES_DB.sqls.clear
    POSTGRES_DB.drop_index :test, [:name, :value], :if_exists=>true, :name=>'tnv1'
    POSTGRES_DB.sqls.should == ['DROP INDEX IF EXISTS "tnv1"']
  end

  specify "should support CASCADE when dropping indexes" do
    POSTGRES_DB.add_index :test, [:name, :value], :name=>'tnv2'
    POSTGRES_DB.sqls.clear
    POSTGRES_DB.drop_index :test, [:name, :value], :cascade=>true, :name=>'tnv2'
    POSTGRES_DB.sqls.should == ['DROP INDEX "tnv2" CASCADE']
  end

  specify "should support dropping indexes concurrently" do
    POSTGRES_DB.add_index :test, [:name, :value], :name=>'tnv2'
    POSTGRES_DB.sqls.clear
    POSTGRES_DB.drop_index :test, [:name, :value], :concurrently=>true, :name=>'tnv2'
    POSTGRES_DB.sqls.should == ['DROP INDEX CONCURRENTLY "tnv2"']
  end if POSTGRES_DB.server_version >= 90200

  specify "#lock should lock table if inside a transaction" do
    POSTGRES_DB.transaction{@d.lock('EXCLUSIVE'); @d.insert(:name=>'a')}
  end

  specify "#lock should return nil" do
    @d.lock('EXCLUSIVE'){@d.insert(:name=>'a')}.should == nil
    POSTGRES_DB.transaction{@d.lock('EXCLUSIVE').should == nil; @d.insert(:name=>'a')}
  end

  specify "should raise an error if attempting to update a joined dataset with a single FROM table" do
    proc{POSTGRES_DB[:test].join(:test2, [:name]).update(:name=>'a')}.should raise_error(Sequel::Error, 'Need multiple FROM tables if updating/deleting a dataset with JOINs')
  end

  specify "should truncate with options" do
    @d << { :name => 'abc', :value => 1}
    @d.count.should == 1
    @d.truncate(:cascade => true)
    @d.count.should == 0
    if @d.db.server_version > 80400
      @d << { :name => 'abc', :value => 1}
      @d.truncate(:cascade => true, :only=>true, :restart=>true)
      @d.count.should == 0
    end
  end

  specify "should truncate multiple tables at once" do
    tables = [:test, :test2, :test3, :test4]
    tables.each{|t| @d.from(t).insert}
    @d.from(:test, :test2, :test3, :test4).truncate
    tables.each{|t| @d.from(t).count.should == 0}
  end
end

describe "Dataset#distinct" do
  before do
    @db = POSTGRES_DB
    @db.create_table!(:a) do
      Integer :a
      Integer :b
    end
    @ds = @db[:a]
  end
  after do
    @db.drop_table?(:a)
  end

  it "#distinct with arguments should return results distinct on those arguments" do
    @ds.insert(20, 10)
    @ds.insert(30, 10)
    @ds.order(:b, :a).distinct.map(:a).should == [20, 30]
    @ds.order(:b, :a.desc).distinct.map(:a).should == [30, 20]
    @ds.order(:b, :a).distinct(:b).map(:a).should == [20]
    @ds.order(:b, :a.desc).distinct(:b).map(:a).should == [30]
  end
end

if POSTGRES_DB.pool.respond_to?(:max_size) and POSTGRES_DB.pool.max_size > 1
  describe "Dataset#for_update support" do
    before do
      @db = POSTGRES_DB.create_table!(:items) do
        primary_key :id
        Integer :number
        String :name
      end
      @ds = POSTGRES_DB[:items]
    end
    after do
      POSTGRES_DB.drop_table?(:items)
      POSTGRES_DB.disconnect
    end

    specify "should handle FOR UPDATE" do
      @ds.insert(:number=>20)
      c, t = nil, nil
      q = Queue.new
      POSTGRES_DB.transaction do
        @ds.for_update.first(:id=>1)
        t = Thread.new do
          POSTGRES_DB.transaction do
            q.push nil
            @ds.filter(:id=>1).update(:name=>'Jim')
            c = @ds.first(:id=>1)
            q.push nil
          end
        end
        q.pop
        @ds.filter(:id=>1).update(:number=>30)
      end
      q.pop
      t.join
      c.should == {:id=>1, :number=>30, :name=>'Jim'}
    end

    specify "should handle FOR SHARE" do
      @ds.insert(:number=>20)
      c, t = nil
      q = Queue.new
      POSTGRES_DB.transaction do
        @ds.for_share.first(:id=>1)
        t = Thread.new do
          POSTGRES_DB.transaction do
            c = @ds.for_share.filter(:id=>1).first
            q.push nil
          end
        end
        q.pop
        @ds.filter(:id=>1).update(:name=>'Jim')
        c.should == {:id=>1, :number=>20, :name=>nil}
      end
      t.join
    end
  end
end

describe "A PostgreSQL dataset with a timestamp field" do
  before do
    @db = POSTGRES_DB
    @d = @db[:test3]
    @d.delete
  end
  after do
    @db.convert_infinite_timestamps = false if @db.adapter_scheme == :postgres
  end

  cspecify "should store milliseconds in time fields for Time objects", :do, :swift do
    t = Time.now
    @d << {:value=>1, :time=>t}
    t2 = @d[:value =>1][:time]
    @d.literal(t2).should == @d.literal(t)
    t2.strftime('%Y-%m-%d %H:%M:%S').should == t.strftime('%Y-%m-%d %H:%M:%S')
    (t2.is_a?(Time) ? t2.usec : t2.strftime('%N').to_i/1000).should == t.usec
  end

  cspecify "should store milliseconds in time fields for DateTime objects", :do, :swift do
    t = DateTime.now
    @d << {:value=>1, :time=>t}
    t2 = @d[:value =>1][:time]
    @d.literal(t2).should == @d.literal(t)
    t2.strftime('%Y-%m-%d %H:%M:%S').should == t.strftime('%Y-%m-%d %H:%M:%S')
    (t2.is_a?(Time) ? t2.usec : t2.strftime('%N').to_i/1000).should == t.strftime('%N').to_i/1000
  end

  if POSTGRES_DB.adapter_scheme == :postgres
    specify "should handle infinite timestamps if convert_infinite_timestamps is set" do
      @d << {:time=>'infinity'.cast(:timestamp)}
      @db.convert_infinite_timestamps = :nil
      @db[:test3].get(:time).should == nil
      @db.convert_infinite_timestamps = :string
      @db[:test3].get(:time).should == 'infinity'
      @db.convert_infinite_timestamps = :float
      @db[:test3].get(:time).should == 1.0/0.0

      @d.update(:time=>'-infinity'.cast(:timestamp))
      @db.convert_infinite_timestamps = :nil
      @db[:test3].get(:time).should == nil
      @db.convert_infinite_timestamps = :string
      @db[:test3].get(:time).should == '-infinity'
      @db.convert_infinite_timestamps = :float
      @db[:test3].get(:time).should == -1.0/0.0
    end

    specify "should handle conversions from infinite strings/floats in models" do
      c = Class.new(Sequel::Model(:test3))
      @db.convert_infinite_timestamps = :float
      c.new(:time=>'infinity').time.should == 'infinity'
      c.new(:time=>'-infinity').time.should == '-infinity'
      c.new(:time=>1.0/0.0).time.should == 1.0/0.0
      c.new(:time=>-1.0/0.0).time.should == -1.0/0.0
    end
  end
end

describe "PostgreSQL's EXPLAIN and ANALYZE" do
  specify "should not raise errors" do
    @d = POSTGRES_DB[:test3]
    proc{@d.explain}.should_not raise_error
    proc{@d.analyze}.should_not raise_error
  end
end

describe "A PostgreSQL database" do
  before do
    @db = POSTGRES_DB
  end

  specify "should support column operations" do
    @db.create_table!(:test2){text :name; integer :value}
    @db[:test2] << {}
    @db[:test2].columns.should == [:name, :value]

    @db.add_column :test2, :xyz, :text, :default => '000'
    @db[:test2].columns.should == [:name, :value, :xyz]
    @db[:test2] << {:name => 'mmm', :value => 111}
    @db[:test2].first[:xyz].should == '000'

    @db[:test2].columns.should == [:name, :value, :xyz]
    @db.drop_column :test2, :xyz

    @db[:test2].columns.should == [:name, :value]

    @db[:test2].delete
    @db.add_column :test2, :xyz, :text, :default => '000'
    @db[:test2] << {:name => 'mmm', :value => 111, :xyz => 'qqqq'}

    @db[:test2].columns.should == [:name, :value, :xyz]
    @db.rename_column :test2, :xyz, :zyx
    @db[:test2].columns.should == [:name, :value, :zyx]
    @db[:test2].first[:zyx].should == 'qqqq'

    @db.add_column :test2, :xyz, :float
    @db[:test2].delete
    @db[:test2] << {:name => 'mmm', :value => 111, :xyz => 56.78}
    @db.set_column_type :test2, :xyz, :integer

    @db[:test2].first[:xyz].should == 57
  end

  specify "#locks should be a dataset returning database locks " do
    @db.locks.should be_a_kind_of(Sequel::Dataset)
    @db.locks.all.should be_a_kind_of(Array)
  end
end

describe "A PostgreSQL database" do
  before do
    @db = POSTGRES_DB
    @db.drop_table?(:posts)
    @db.sqls.clear
  end
  after do
    @db.drop_table?(:posts)
  end

  specify "should support resetting the primary key sequence" do
    @db.create_table(:posts){primary_key :a}
    @db[:posts].insert(:a=>20).should == 20
    @db[:posts].insert.should == 1
    @db[:posts].insert.should == 2
    @db[:posts].insert(:a=>10).should == 10
    @db.reset_primary_key_sequence(:posts).should == 21
    @db[:posts].insert.should == 21
    @db[:posts].order(:a).map(:a).should == [1, 2, 10, 20, 21]
  end

  specify "should support specifying Integer/Bignum/Fixnum types in primary keys and have them be auto incrementing" do
    @db.create_table(:posts){primary_key :a, :type=>Integer}
    @db[:posts].insert.should == 1
    @db[:posts].insert.should == 2
    @db.create_table!(:posts){primary_key :a, :type=>Fixnum}
    @db[:posts].insert.should == 1
    @db[:posts].insert.should == 2
    @db.create_table!(:posts){primary_key :a, :type=>Bignum}
    @db[:posts].insert.should == 1
    @db[:posts].insert.should == 2
  end

  specify "should not raise an error if attempting to resetting the primary key sequence for a table without a primary key" do
    @db.create_table(:posts){Integer :a}
    @db.reset_primary_key_sequence(:posts).should == nil
  end

  specify "should support opclass specification" do
    @db.create_table(:posts){text :title; text :body; integer :user_id; index(:user_id, :opclass => :int4_ops, :type => :btree)}
    @db.sqls.should == [
    'CREATE TABLE "posts" ("title" text, "body" text, "user_id" integer)',
    'CREATE INDEX "posts_user_id_index" ON "posts" USING btree ("user_id" int4_ops)'
    ]
  end

  specify "should support fulltext indexes and searching" do
    @db.create_table(:posts){text :title; text :body; full_text_index [:title, :body]; full_text_index :title, :language => 'french'}
    @db.sqls.should == [
      %{CREATE TABLE "posts" ("title" text, "body" text)},
      %{CREATE INDEX "posts_title_body_index" ON "posts" USING gin (to_tsvector('simple'::regconfig, (COALESCE("title", '') || ' ' || COALESCE("body", ''))))},
      %{CREATE INDEX "posts_title_index" ON "posts" USING gin (to_tsvector('french'::regconfig, (COALESCE("title", ''))))}
    ] if check_sqls

    @db[:posts].insert(:title=>'ruby rails', :body=>'yowsa')
    @db[:posts].insert(:title=>'sequel', :body=>'ruby')
    @db[:posts].insert(:title=>'ruby scooby', :body=>'x')
    @db.sqls.clear

    @db[:posts].full_text_search(:title, 'rails').all.should == [{:title=>'ruby rails', :body=>'yowsa'}]
    @db[:posts].full_text_search([:title, :body], ['yowsa', 'rails']).all.should == [:title=>'ruby rails', :body=>'yowsa']
    @db[:posts].full_text_search(:title, 'scooby', :language => 'french').all.should == [{:title=>'ruby scooby', :body=>'x'}]
    @db.sqls.should == [
      %{SELECT * FROM "posts" WHERE (to_tsvector('simple'::regconfig, (COALESCE("title", ''))) @@ to_tsquery('simple'::regconfig, 'rails'))},
      %{SELECT * FROM "posts" WHERE (to_tsvector('simple'::regconfig, (COALESCE("title", '') || ' ' || COALESCE("body", ''))) @@ to_tsquery('simple'::regconfig, 'yowsa | rails'))},
      %{SELECT * FROM "posts" WHERE (to_tsvector('french'::regconfig, (COALESCE("title", ''))) @@ to_tsquery('french'::regconfig, 'scooby'))}] if check_sqls

    @db[:posts].full_text_search(:title, :$n).call(:select, :n=>'rails').should == [{:title=>'ruby rails', :body=>'yowsa'}]
    @db[:posts].full_text_search(:title, :$n).prepare(:select, :fts_select).call(:n=>'rails').should == [{:title=>'ruby rails', :body=>'yowsa'}]
  end

  specify "should support spatial indexes" do
    @db.create_table(:posts){box :geom; spatial_index [:geom]}
    @db.sqls.should == [
      'CREATE TABLE "posts" ("geom" box)',
      'CREATE INDEX "posts_geom_index" ON "posts" USING gist ("geom")'
    ]
  end

  specify "should support indexes with index type" do
    @db.create_table(:posts){varchar :title, :size => 5; index :title, :type => 'hash'}
    @db.sqls.should == [
      'CREATE TABLE "posts" ("title" varchar(5))',
      'CREATE INDEX "posts_title_index" ON "posts" USING hash ("title")'
    ]
  end

  specify "should support unique indexes with index type" do
    @db.create_table(:posts){varchar :title, :size => 5; index :title, :type => 'btree', :unique => true}
    @db.sqls.should == [
      'CREATE TABLE "posts" ("title" varchar(5))',
      'CREATE UNIQUE INDEX "posts_title_index" ON "posts" USING btree ("title")'
    ]
  end

  specify "should support partial indexes" do
    @db.create_table(:posts){varchar :title, :size => 5; index :title, :where => {:title => '5'}}
    @db.sqls.should == [
      'CREATE TABLE "posts" ("title" varchar(5))',
      'CREATE INDEX "posts_title_index" ON "posts" ("title") WHERE ("title" = \'5\')'
    ]
  end

  specify "should support identifiers for table names in indicies" do
    @db.create_table(Sequel::SQL::Identifier.new(:posts)){varchar :title, :size => 5; index :title, :where => {:title => '5'}}
    @db.sqls.should == [
      'CREATE TABLE "posts" ("title" varchar(5))',
      'CREATE INDEX "posts_title_index" ON "posts" ("title") WHERE ("title" = \'5\')'
    ]
  end

  specify "should support renaming tables" do
    @db.create_table!(:posts1){primary_key :a}
    @db.rename_table(:posts1, :posts)
  end
end

describe "Postgres::Dataset#import" do
  before do
    @db = POSTGRES_DB
    @db.create_table!(:test){primary_key :x; Integer :y}
    @db.sqls.clear
    @ds = @db[:test]
  end
  after do
    @db.drop_table?(:test)
  end


  specify "#import should a single insert statement" do
    @ds.import([:x, :y], [[1, 2], [3, 4]])
    @db.sqls.should == ['BEGIN', 'INSERT INTO "test" ("x", "y") VALUES (1, 2), (3, 4)', 'COMMIT']
    @ds.all.should == [{:x=>1, :y=>2}, {:x=>3, :y=>4}]
  end

  specify "#import should work correctly when returning primary keys" do
    @ds.import([:x, :y], [[1, 2], [3, 4]], :return=>:primary_key).should == [1, 3]
    @ds.all.should == [{:x=>1, :y=>2}, {:x=>3, :y=>4}]
  end

  specify "#import should work correctly when returning primary keys with :slice option" do
    @ds.import([:x, :y], [[1, 2], [3, 4]], :return=>:primary_key, :slice=>1).should == [1, 3]
    @ds.all.should == [{:x=>1, :y=>2}, {:x=>3, :y=>4}]
  end

  specify "#import should work correctly with an arbitrary returning value" do
    @ds.returning(:y, :x).import([:x, :y], [[1, 2], [3, 4]]).should == [{:y=>2, :x=>1}, {:y=>4, :x=>3}]
    @ds.all.should == [{:x=>1, :y=>2}, {:x=>3, :y=>4}]
  end
end

describe "Postgres::Dataset#insert" do
  before do
    @db = POSTGRES_DB
    @db.create_table!(:test5){primary_key :xid; Integer :value}
    @db.sqls.clear
    @ds = @db[:test5]
  end
  after do
    @db.drop_table?(:test5)
  end

  specify "should work with static SQL" do
    @ds.with_sql('INSERT INTO test5 (value) VALUES (10)').insert.should == nil
    @db['INSERT INTO test5 (value) VALUES (20)'].insert.should == nil
    @ds.all.should == [{:xid=>1, :value=>10}, {:xid=>2, :value=>20}]
  end

  specify "should insert correctly if using a column array and a value array" do
    @ds.insert([:value], [10]).should == 1
    @ds.all.should == [{:xid=>1, :value=>10}]
  end

  specify "should use INSERT RETURNING" do
    @ds.insert(:value=>10).should == 1
    @db.sqls.last.should == 'INSERT INTO "test5" ("value") VALUES (10) RETURNING "xid"' if check_sqls
  end

  specify "should have insert_select insert the record and return the inserted record" do
    h = @ds.insert_select(:value=>10)
    h[:value].should == 10
    @ds.first(:xid=>h[:xid])[:value].should == 10
  end

  specify "should correctly return the inserted record's primary key value" do
    value1 = 10
    id1 = @ds.insert(:value=>value1)
    @ds.first(:xid=>id1)[:value].should == value1
    value2 = 20
    id2 = @ds.insert(:value=>value2)
    @ds.first(:xid=>id2)[:value].should == value2
  end

  specify "should return nil if the table has no primary key" do
    ds = POSTGRES_DB[:test4]
    ds.delete
    ds.insert(:name=>'a').should == nil
  end
end

describe "Postgres::Database schema qualified tables" do
  before do
    POSTGRES_DB << "CREATE SCHEMA schema_test"
    POSTGRES_DB.instance_variable_set(:@primary_keys, {})
    POSTGRES_DB.instance_variable_set(:@primary_key_sequences, {})
  end
  after do
    POSTGRES_DB << "DROP SCHEMA schema_test CASCADE"
    POSTGRES_DB.default_schema = nil
  end

  specify "should be able to create, drop, select and insert into tables in a given schema" do
    POSTGRES_DB.create_table(:schema_test__schema_test){primary_key :i}
    POSTGRES_DB[:schema_test__schema_test].first.should == nil
    POSTGRES_DB[:schema_test__schema_test].insert(:i=>1).should == 1
    POSTGRES_DB[:schema_test__schema_test].first.should == {:i=>1}
    POSTGRES_DB.from('schema_test.schema_test'.lit).first.should == {:i=>1}
    POSTGRES_DB.drop_table(:schema_test__schema_test)
    POSTGRES_DB.create_table(:schema_test.qualify(:schema_test)){integer :i}
    POSTGRES_DB[:schema_test__schema_test].first.should == nil
    POSTGRES_DB.from('schema_test.schema_test'.lit).first.should == nil
    POSTGRES_DB.drop_table(:schema_test.qualify(:schema_test))
  end

  specify "#tables should not include tables in a default non-public schema" do
    POSTGRES_DB.create_table(:schema_test__schema_test){integer :i}
    POSTGRES_DB.tables.should include(:schema_test)
    POSTGRES_DB.tables.should_not include(:pg_am)
    POSTGRES_DB.tables.should_not include(:domain_udt_usage)
  end

  specify "#tables should return tables in the schema provided by the :schema argument" do
    POSTGRES_DB.create_table(:schema_test__schema_test){integer :i}
    POSTGRES_DB.tables(:schema=>:schema_test).should == [:schema_test]
  end

  specify "#schema should not include columns from tables in a default non-public schema" do
    POSTGRES_DB.create_table(:schema_test__domains){integer :i}
    sch = POSTGRES_DB.schema(:domains)
    cs = sch.map{|x| x.first}
    cs.should include(:i)
    cs.should_not include(:data_type)
  end

  specify "#schema should only include columns from the table in the given :schema argument" do
    POSTGRES_DB.create_table!(:domains){integer :d}
    POSTGRES_DB.create_table(:schema_test__domains){integer :i}
    sch = POSTGRES_DB.schema(:domains, :schema=>:schema_test)
    cs = sch.map{|x| x.first}
    cs.should include(:i)
    cs.should_not include(:d)
    POSTGRES_DB.drop_table(:domains)
  end

  specify "#schema should raise an exception if columns from tables in two separate schema are returned" do
    POSTGRES_DB.create_table!(:public__domains){integer :d}
    POSTGRES_DB.create_table(:schema_test__domains){integer :i}
    begin
      proc{POSTGRES_DB.schema(:domains)}.should raise_error(Sequel::Error)
      POSTGRES_DB.schema(:public__domains).map{|x| x.first}.should == [:d]
      POSTGRES_DB.schema(:schema_test__domains).map{|x| x.first}.should == [:i]
    ensure
      POSTGRES_DB.drop_table?(:public__domains)
    end
  end

  specify "#table_exists? should see if the table is in a given schema" do
    POSTGRES_DB.create_table(:schema_test__schema_test){integer :i}
    POSTGRES_DB.table_exists?(:schema_test__schema_test).should == true
  end

  specify "should be able to get primary keys for tables in a given schema" do
    POSTGRES_DB.create_table(:schema_test__schema_test){primary_key :i}
    POSTGRES_DB.primary_key(:schema_test__schema_test).should == 'i'
  end

  specify "should be able to get serial sequences for tables in a given schema" do
    POSTGRES_DB.create_table(:schema_test__schema_test){primary_key :i}
    POSTGRES_DB.primary_key_sequence(:schema_test__schema_test).should == '"schema_test".schema_test_i_seq'
  end

  specify "should be able to get serial sequences for tables that have spaces in the name in a given schema" do
    POSTGRES_DB.create_table(:"schema_test__schema test"){primary_key :i}
    POSTGRES_DB.primary_key_sequence(:"schema_test__schema test").should == '"schema_test"."schema test_i_seq"'
  end

  specify "should be able to get custom sequences for tables in a given schema" do
    POSTGRES_DB << "CREATE SEQUENCE schema_test.kseq"
    POSTGRES_DB.create_table(:schema_test__schema_test){integer :j; primary_key :k, :type=>:integer, :default=>"nextval('schema_test.kseq'::regclass)".lit}
    POSTGRES_DB.primary_key_sequence(:schema_test__schema_test).should == '"schema_test".kseq'
  end

  specify "should be able to get custom sequences for tables that have spaces in the name in a given schema" do
    POSTGRES_DB << "CREATE SEQUENCE schema_test.\"ks eq\""
    POSTGRES_DB.create_table(:"schema_test__schema test"){integer :j; primary_key :k, :type=>:integer, :default=>"nextval('schema_test.\"ks eq\"'::regclass)".lit}
    POSTGRES_DB.primary_key_sequence(:"schema_test__schema test").should == '"schema_test"."ks eq"'
  end

  specify "#default_schema= should change the default schema used from public" do
    POSTGRES_DB.create_table(:schema_test__schema_test){primary_key :i}
    POSTGRES_DB.default_schema = :schema_test
    POSTGRES_DB.table_exists?(:schema_test).should == true
    POSTGRES_DB.tables.should == [:schema_test]
    POSTGRES_DB.primary_key(:schema_test__schema_test).should == 'i'
    POSTGRES_DB.primary_key_sequence(:schema_test__schema_test).should == '"schema_test".schema_test_i_seq'
  end
end

describe "Postgres::Database schema qualified tables and eager graphing" do
  before(:all) do
    @db = POSTGRES_DB
    @db.run "DROP SCHEMA s CASCADE" rescue nil
    @db.run "CREATE SCHEMA s"

    @db.create_table(:s__bands){primary_key :id; String :name}
    @db.create_table(:s__albums){primary_key :id; String :name; foreign_key :band_id, :s__bands}
    @db.create_table(:s__tracks){primary_key :id; String :name; foreign_key :album_id, :s__albums}
    @db.create_table(:s__members){primary_key :id; String :name; foreign_key :band_id, :s__bands}

    @Band = Class.new(Sequel::Model(:s__bands))
    @Album = Class.new(Sequel::Model(:s__albums))
    @Track = Class.new(Sequel::Model(:s__tracks))
    @Member = Class.new(Sequel::Model(:s__members))
    def @Band.name; :Band; end
    def @Album.name; :Album; end
    def @Track.name; :Track; end
    def @Member.name; :Member; end

    @Band.one_to_many :albums, :class=>@Album, :order=>:name
    @Band.one_to_many :members, :class=>@Member, :order=>:name
    @Album.many_to_one :band, :class=>@Band, :order=>:name
    @Album.one_to_many :tracks, :class=>@Track, :order=>:name
    @Track.many_to_one :album, :class=>@Album, :order=>:name
    @Member.many_to_one :band, :class=>@Band, :order=>:name

    @Member.many_to_many :members, :class=>@Member, :join_table=>:s__bands, :right_key=>:id, :left_key=>:id, :left_primary_key=>:band_id, :right_primary_key=>:band_id, :order=>:name
    @Band.many_to_many :tracks, :class=>@Track, :join_table=>:s__albums, :right_key=>:id, :right_primary_key=>:album_id, :order=>:name

    @b1 = @Band.create(:name=>"BM")
    @b2 = @Band.create(:name=>"J")
    @a1 = @Album.create(:name=>"BM1", :band=>@b1)
    @a2 = @Album.create(:name=>"BM2", :band=>@b1)
    @a3 = @Album.create(:name=>"GH", :band=>@b2)
    @a4 = @Album.create(:name=>"GHL", :band=>@b2)
    @t1 = @Track.create(:name=>"BM1-1", :album=>@a1)
    @t2 = @Track.create(:name=>"BM1-2", :album=>@a1)
    @t3 = @Track.create(:name=>"BM2-1", :album=>@a2)
    @t4 = @Track.create(:name=>"BM2-2", :album=>@a2)
    @m1 = @Member.create(:name=>"NU", :band=>@b1)
    @m2 = @Member.create(:name=>"TS", :band=>@b1)
    @m3 = @Member.create(:name=>"NS", :band=>@b2)
    @m4 = @Member.create(:name=>"JC", :band=>@b2)
  end
  after(:all) do
    @db.run "DROP SCHEMA s CASCADE"
  end

  specify "should return all eager graphs correctly" do
    bands = @Band.order(:bands__name).eager_graph(:albums).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.albums}.should == [[@a1, @a2], [@a3, @a4]]

    bands = @Band.order(:bands__name).eager_graph(:albums=>:tracks).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.albums}.should == [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.albums.map{|y| y.tracks}}.should == [[[@t1, @t2], [@t3, @t4]], [[], []]]

    bands = @Band.order(:bands__name).eager_graph({:albums=>:tracks}, :members).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.albums}.should == [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.albums.map{|y| y.tracks}}.should == [[[@t1, @t2], [@t3, @t4]], [[], []]]
    bands.map{|x| x.members}.should == [[@m1, @m2], [@m4, @m3]]
  end

  specify "should have eager graphs work with previous joins" do
    bands = @Band.order(:bands__name).select(:s__bands.*).join(:s__members, :band_id=>:id).from_self(:alias=>:bands0).eager_graph(:albums=>:tracks).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.albums}.should == [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.albums.map{|y| y.tracks}}.should == [[[@t1, @t2], [@t3, @t4]], [[], []]]
  end

  specify "should have eager graphs work with joins with the same tables" do
    bands = @Band.order(:bands__name).select(:s__bands.*).join(:s__members, :band_id=>:id).eager_graph({:albums=>:tracks}, :members).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.albums}.should == [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.albums.map{|y| y.tracks}}.should == [[[@t1, @t2], [@t3, @t4]], [[], []]]
    bands.map{|x| x.members}.should == [[@m1, @m2], [@m4, @m3]]
  end

  specify "should have eager graphs work with self referential associations" do
    bands = @Band.order(:bands__name).eager_graph(:tracks=>{:album=>:band}).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.tracks}.should == [[@t1, @t2, @t3, @t4], []]
    bands.map{|x| x.tracks.map{|y| y.album}}.should == [[@a1, @a1, @a2, @a2], []]
    bands.map{|x| x.tracks.map{|y| y.album.band}}.should == [[@b1, @b1, @b1, @b1], []]

    members = @Member.order(:members__name).eager_graph(:members).all
    members.should == [@m4, @m3, @m1, @m2]
    members.map{|x| x.members}.should == [[@m4, @m3], [@m4, @m3], [@m1, @m2], [@m1, @m2]]

    members = @Member.order(:members__name).eager_graph(:band, :members=>:band).all
    members.should == [@m4, @m3, @m1, @m2]
    members.map{|x| x.band}.should == [@b2, @b2, @b1, @b1]
    members.map{|x| x.members}.should == [[@m4, @m3], [@m4, @m3], [@m1, @m2], [@m1, @m2]]
    members.map{|x| x.members.map{|y| y.band}}.should == [[@b2, @b2], [@b2, @b2], [@b1, @b1], [@b1, @b1]]
  end

  specify "should have eager graphs work with a from_self dataset" do
    bands = @Band.order(:bands__name).from_self.eager_graph(:tracks=>{:album=>:band}).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.tracks}.should == [[@t1, @t2, @t3, @t4], []]
    bands.map{|x| x.tracks.map{|y| y.album}}.should == [[@a1, @a1, @a2, @a2], []]
    bands.map{|x| x.tracks.map{|y| y.album.band}}.should == [[@b1, @b1, @b1, @b1], []]
  end

  specify "should have eager graphs work with different types of aliased from tables" do
    bands = @Band.order(:tracks__name).from(:s__bands___tracks).eager_graph(:tracks).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.tracks}.should == [[@t1, @t2, @t3, @t4], []]

    bands = @Band.order(:tracks__name).from(:s__bands.as(:tracks)).eager_graph(:tracks).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.tracks}.should == [[@t1, @t2, @t3, @t4], []]

    bands = @Band.order(:tracks__name).from(:s__bands.as(:tracks.identifier)).eager_graph(:tracks).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.tracks}.should == [[@t1, @t2, @t3, @t4], []]

    bands = @Band.order(:tracks__name).from(:s__bands.as('tracks')).eager_graph(:tracks).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.tracks}.should == [[@t1, @t2, @t3, @t4], []]
  end

  specify "should have eager graphs work with join tables with aliases" do
    bands = @Band.order(:bands__name).eager_graph(:members).join(:s__albums___tracks, :band_id=>:id.qualify(:s__bands)).eager_graph(:albums=>:tracks).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.albums}.should == [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.members}.should == [[@m1, @m2], [@m4, @m3]]

    bands = @Band.order(:bands__name).eager_graph(:members).join(:s__albums.as(:tracks), :band_id=>:id.qualify(:s__bands)).eager_graph(:albums=>:tracks).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.albums}.should == [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.members}.should == [[@m1, @m2], [@m4, @m3]]

    bands = @Band.order(:bands__name).eager_graph(:members).join(:s__albums.as('tracks'), :band_id=>:id.qualify(:s__bands)).eager_graph(:albums=>:tracks).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.albums}.should == [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.members}.should == [[@m1, @m2], [@m4, @m3]]

    bands = @Band.order(:bands__name).eager_graph(:members).join(:s__albums.as(:tracks.identifier), :band_id=>:id.qualify(:s__bands)).eager_graph(:albums=>:tracks).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.albums}.should == [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.members}.should == [[@m1, @m2], [@m4, @m3]]

    bands = @Band.order(:bands__name).eager_graph(:members).join(:s__albums, {:band_id=>:id.qualify(:s__bands)}, :table_alias=>:tracks).eager_graph(:albums=>:tracks).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.albums}.should == [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.members}.should == [[@m1, @m2], [@m4, @m3]]

    bands = @Band.order(:bands__name).eager_graph(:members).join(:s__albums, {:band_id=>:id.qualify(:s__bands)}, :table_alias=>'tracks').eager_graph(:albums=>:tracks).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.albums}.should == [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.members}.should == [[@m1, @m2], [@m4, @m3]]

    bands = @Band.order(:bands__name).eager_graph(:members).join(:s__albums, {:band_id=>:id.qualify(:s__bands)}, :table_alias=>:tracks.identifier).eager_graph(:albums=>:tracks).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.albums}.should == [[@a1, @a2], [@a3, @a4]]
    bands.map{|x| x.members}.should == [[@m1, @m2], [@m4, @m3]]
  end

  specify "should have eager graphs work with different types of qualified from tables" do
    bands = @Band.order(:bands__name).from(:bands.qualify(:s)).eager_graph(:tracks).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.tracks}.should == [[@t1, @t2, @t3, @t4], []]

    bands = @Band.order(:bands__name).from(:bands.identifier.qualify(:s)).eager_graph(:tracks).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.tracks}.should == [[@t1, @t2, @t3, @t4], []]

    bands = @Band.order(:bands__name).from(Sequel::SQL::QualifiedIdentifier.new(:s, 'bands')).eager_graph(:tracks).all
    bands.should == [@b1, @b2]
    bands.map{|x| x.tracks}.should == [[@t1, @t2, @t3, @t4], []]
  end

end

if POSTGRES_DB.server_version >= 80300

  POSTGRES_DB.create_table! :test6 do
    text :title
    text :body
    full_text_index [:title, :body]
  end

  describe "PostgreSQL tsearch2" do
    before do
      @ds = POSTGRES_DB[:test6]
    end
    after do
      POSTGRES_DB[:test6].delete
    end

    specify "should search by indexed column" do
      record =  {:title => "oopsla conference", :body => "test"}
      @ds << record
      @ds.full_text_search(:title, "oopsla").all.should include(record)
    end

    specify "should join multiple coumns with spaces to search by last words in row" do
      record = {:title => "multiple words", :body => "are easy to search"}
      @ds << record
      @ds.full_text_search([:title, :body], "words").all.should include(record)
    end

    specify "should return rows with a NULL in one column if a match in another column" do
      record = {:title => "multiple words", :body =>nil}
      @ds << record
      @ds.full_text_search([:title, :body], "words").all.should include(record)
    end
  end
end

if POSTGRES_DB.dataset.supports_window_functions?
  describe "Postgres::Dataset named windows" do
    before do
      @db = POSTGRES_DB
      @db.create_table!(:i1){Integer :id; Integer :group_id; Integer :amount}
      @ds = @db[:i1].order(:id)
      @ds.insert(:id=>1, :group_id=>1, :amount=>1)
      @ds.insert(:id=>2, :group_id=>1, :amount=>10)
      @ds.insert(:id=>3, :group_id=>1, :amount=>100)
      @ds.insert(:id=>4, :group_id=>2, :amount=>1000)
      @ds.insert(:id=>5, :group_id=>2, :amount=>10000)
      @ds.insert(:id=>6, :group_id=>2, :amount=>100000)
    end
    after do
      @db.drop_table?(:i1)
    end

    specify "should give correct results for window functions" do
      @ds.window(:win, :partition=>:group_id, :order=>:id).select(:id){sum(:over, :args=>amount, :window=>win){}}.all.should ==
        [{:sum=>1, :id=>1}, {:sum=>11, :id=>2}, {:sum=>111, :id=>3}, {:sum=>1000, :id=>4}, {:sum=>11000, :id=>5}, {:sum=>111000, :id=>6}]
      @ds.window(:win, :partition=>:group_id).select(:id){sum(:over, :args=>amount, :window=>win, :order=>id){}}.all.should ==
        [{:sum=>1, :id=>1}, {:sum=>11, :id=>2}, {:sum=>111, :id=>3}, {:sum=>1000, :id=>4}, {:sum=>11000, :id=>5}, {:sum=>111000, :id=>6}]
      @ds.window(:win, {}).select(:id){sum(:over, :args=>amount, :window=>:win, :order=>id){}}.all.should ==
        [{:sum=>1, :id=>1}, {:sum=>11, :id=>2}, {:sum=>111, :id=>3}, {:sum=>1111, :id=>4}, {:sum=>11111, :id=>5}, {:sum=>111111, :id=>6}]
      @ds.window(:win, :partition=>:group_id).select(:id){sum(:over, :args=>amount, :window=>:win, :order=>id, :frame=>:all){}}.all.should ==
        [{:sum=>111, :id=>1}, {:sum=>111, :id=>2}, {:sum=>111, :id=>3}, {:sum=>111000, :id=>4}, {:sum=>111000, :id=>5}, {:sum=>111000, :id=>6}]
    end
  end
end

describe "Postgres::Database functions, languages, schemas, and triggers" do
  before do
    @d = POSTGRES_DB
  end
  after do
    @d.drop_function('tf', :if_exists=>true, :cascade=>true)
    @d.drop_function('tf', :if_exists=>true, :cascade=>true, :args=>%w'integer integer')
    @d.drop_language(:plpgsql, :if_exists=>true, :cascade=>true) if @d.server_version < 90000
    @d.drop_schema(:sequel, :if_exists=>true, :cascade=>true)
    @d.drop_table?(:test)
  end

  specify "#create_function and #drop_function should create and drop functions" do
    proc{@d['SELECT tf()'].all}.should raise_error(Sequel::DatabaseError)
    args = ['tf', 'SELECT 1', {:returns=>:integer}]
    @d.send(:create_function_sql, *args).should =~ /\A\s*CREATE FUNCTION tf\(\)\s+RETURNS integer\s+LANGUAGE SQL\s+AS 'SELECT 1'\s*\z/
    @d.create_function(*args)
    rows = @d['SELECT tf()'].all.should == [{:tf=>1}]
    @d.send(:drop_function_sql, 'tf').should == 'DROP FUNCTION tf()'
    @d.drop_function('tf')
    proc{@d['SELECT tf()'].all}.should raise_error(Sequel::DatabaseError)
  end

  specify "#create_function and #drop_function should support options" do
    args = ['tf', 'SELECT $1 + $2', {:args=>[[:integer, :a], :integer], :replace=>true, :returns=>:integer, :language=>'SQL', :behavior=>:immutable, :strict=>true, :security_definer=>true, :cost=>2, :set=>{:search_path => 'public'}}]
    @d.send(:create_function_sql,*args).should =~ /\A\s*CREATE OR REPLACE FUNCTION tf\(a integer, integer\)\s+RETURNS integer\s+LANGUAGE SQL\s+IMMUTABLE\s+STRICT\s+SECURITY DEFINER\s+COST 2\s+SET search_path = public\s+AS 'SELECT \$1 \+ \$2'\s*\z/
    @d.create_function(*args)
    # Make sure replace works
    @d.create_function(*args)
    rows = @d['SELECT tf(1, 2)'].all.should == [{:tf=>3}]
    args = ['tf', {:if_exists=>true, :cascade=>true, :args=>[[:integer, :a], :integer]}]
    @d.send(:drop_function_sql,*args).should == 'DROP FUNCTION IF EXISTS tf(a integer, integer) CASCADE'
    @d.drop_function(*args)
    # Make sure if exists works
    @d.drop_function(*args)
  end

  specify "#create_language and #drop_language should create and drop languages" do
    @d.send(:create_language_sql, :plpgsql).should == 'CREATE LANGUAGE plpgsql'
    @d.create_language(:plpgsql, :replace=>true) if @d.server_version < 90000
    proc{@d.create_language(:plpgsql)}.should raise_error(Sequel::DatabaseError)
    @d.send(:drop_language_sql, :plpgsql).should == 'DROP LANGUAGE plpgsql'
    @d.drop_language(:plpgsql) if @d.server_version < 90000
    proc{@d.drop_language(:plpgsql)}.should raise_error(Sequel::DatabaseError) if @d.server_version < 90000
    @d.send(:create_language_sql, :plpgsql, :replace=>true, :trusted=>true, :handler=>:a, :validator=>:b).should == (@d.server_version >= 90000 ? 'CREATE OR REPLACE TRUSTED LANGUAGE plpgsql HANDLER a VALIDATOR b' : 'CREATE TRUSTED LANGUAGE plpgsql HANDLER a VALIDATOR b')
    @d.send(:drop_language_sql, :plpgsql, :if_exists=>true, :cascade=>true).should == 'DROP LANGUAGE IF EXISTS plpgsql CASCADE'
    # Make sure if exists works
    @d.drop_language(:plpgsql, :if_exists=>true, :cascade=>true) if @d.server_version < 90000
  end

  specify "#create_schema and #drop_schema should create and drop schemas" do
    @d.send(:create_schema_sql, :sequel).should == 'CREATE SCHEMA "sequel"'
    @d.send(:drop_schema_sql, :sequel).should == 'DROP SCHEMA "sequel"'
    @d.send(:drop_schema_sql, :sequel, :if_exists=>true, :cascade=>true).should == 'DROP SCHEMA IF EXISTS "sequel" CASCADE'
    @d.create_schema(:sequel)
    @d.create_table(:sequel__test){Integer :a}
    @d.drop_schema(:sequel, :if_exists=>true, :cascade=>true)
  end

  specify "#create_trigger and #drop_trigger should create and drop triggers" do
    @d.create_language(:plpgsql) if @d.server_version < 90000
    @d.create_function(:tf, 'BEGIN IF NEW.value IS NULL THEN RAISE EXCEPTION \'Blah\'; END IF; RETURN NEW; END;', :language=>:plpgsql, :returns=>:trigger)
    @d.send(:create_trigger_sql, :test, :identity, :tf, :each_row=>true).should == 'CREATE TRIGGER identity BEFORE INSERT OR UPDATE OR DELETE ON "test" FOR EACH ROW EXECUTE PROCEDURE tf()'
    @d.create_table(:test){String :name; Integer :value}
    @d.create_trigger(:test, :identity, :tf, :each_row=>true)
    @d[:test].insert(:name=>'a', :value=>1)
    @d[:test].filter(:name=>'a').all.should == [{:name=>'a', :value=>1}]
    proc{@d[:test].filter(:name=>'a').update(:value=>nil)}.should raise_error(Sequel::DatabaseError)
    @d[:test].filter(:name=>'a').all.should == [{:name=>'a', :value=>1}]
    @d[:test].filter(:name=>'a').update(:value=>3)
    @d[:test].filter(:name=>'a').all.should == [{:name=>'a', :value=>3}]
    @d.send(:drop_trigger_sql, :test, :identity).should == 'DROP TRIGGER identity ON "test"'
    @d.drop_trigger(:test, :identity)
    @d.send(:create_trigger_sql, :test, :identity, :tf, :after=>true, :events=>:insert, :args=>[1, 'a']).should == 'CREATE TRIGGER identity AFTER INSERT ON "test" EXECUTE PROCEDURE tf(1, \'a\')'
    @d.send(:drop_trigger_sql, :test, :identity, :if_exists=>true, :cascade=>true).should == 'DROP TRIGGER IF EXISTS identity ON "test" CASCADE'
    # Make sure if exists works
    @d.drop_trigger(:test, :identity, :if_exists=>true, :cascade=>true)
  end
end

if POSTGRES_DB.adapter_scheme == :postgres
  describe "Postgres::Dataset #use_cursor" do
    before(:all) do
      @db = POSTGRES_DB
      @db.create_table!(:test_cursor){Integer :x}
      @db.sqls.clear
      @ds = @db[:test_cursor]
      @db.transaction{1001.times{|i| @ds.insert(i)}}
    end
    after(:all) do
      @db.drop_table?(:test_cursor)
    end

    specify "should return the same results as the non-cursor use" do
      @ds.all.should == @ds.use_cursor.all
    end

    specify "should respect the :rows_per_fetch option" do
      @db.sqls.clear
      @ds.use_cursor.all
      @db.sqls.length.should == 6
      @db.sqls.clear
      @ds.use_cursor(:rows_per_fetch=>100).all
      @db.sqls.length.should == 15
    end

    specify "should handle returning inside block" do
      def @ds.check_return
        use_cursor.each{|r| return}
      end
      @ds.check_return
      @ds.all.should == @ds.use_cursor.all
    end
  end

  describe "Postgres::PG_NAMED_TYPES" do
    before do
      @db = POSTGRES_DB
      Sequel::Postgres::PG_NAMED_TYPES[:interval] = lambda{|v| v.reverse}
      @db.reset_conversion_procs
    end
    after do
      Sequel::Postgres::PG_NAMED_TYPES.delete(:interval)
      @db.reset_conversion_procs
      @db.drop_table?(:foo)
    end

    specify "should look up conversion procs by name" do
      @db.create_table!(:foo){interval :bar}
      @db[:foo].insert('21 days'.cast(:interval))
      @db[:foo].get(:bar).should == 'syad 12'
    end
  end
end

if POSTGRES_DB.adapter_scheme == :postgres && SEQUEL_POSTGRES_USES_PG && POSTGRES_DB.server_version >= 90000
  describe "Postgres::Database#copy_table" do
    before(:all) do
      @db = POSTGRES_DB
      @db.create_table!(:test_copy){Integer :x; Integer :y}
      ds = @db[:test_copy]
      ds.insert(1, 2)
      ds.insert(3, 4)
    end
    after(:all) do
      @db.drop_table?(:test_copy)
    end

    specify "without a block or options should return a text version of the table as a single string" do
      @db.copy_table(:test_copy).should == "1\t2\n3\t4\n"
    end

    specify "without a block and with :format=>:csv should return a csv version of the table as a single string" do
      @db.copy_table(:test_copy, :format=>:csv).should == "1,2\n3,4\n"
    end

    specify "should treat string as SQL code" do
      @db.copy_table('COPY "test_copy" TO STDOUT').should == "1\t2\n3\t4\n"
    end

    specify "should respect given :options options" do
      @db.copy_table(:test_copy, :options=>"FORMAT csv, HEADER TRUE").should == "x,y\n1,2\n3,4\n"
    end

    specify "should respect given :options options when :format is used" do
      @db.copy_table(:test_copy, :format=>:csv, :options=>"QUOTE '''', FORCE_QUOTE *").should == "'1','2'\n'3','4'\n"
    end

    specify "should accept dataset as first argument" do
      @db.copy_table(@db[:test_copy].cross_join(:test_copy___tc).order(:test_copy__x, :test_copy__y, :tc__x, :tc__y)).should == "1\t2\t1\t2\n1\t2\t3\t4\n3\t4\t1\t2\n3\t4\t3\t4\n"
    end

    specify "with a block and no options should yield each row as a string in text format" do
      buf = []
      @db.copy_table(:test_copy){|b| buf << b}
      buf.should == ["1\t2\n", "3\t4\n"]
    end

    specify "with a block and :format=>:csv should yield each row as a string in csv format" do
      buf = []
      @db.copy_table(:test_copy, :format=>:csv){|b| buf << b}
      buf.should == ["1,2\n", "3,4\n"]
    end

    specify "should work fine when using a block that is terminated early with a following copy_table" do
      buf = []
      proc{@db.copy_table(:test_copy, :format=>:csv){|b| buf << b; break}}.should raise_error(Sequel::DatabaseDisconnectError)
      buf.should == ["1,2\n"]
      buf.clear
      proc{@db.copy_table(:test_copy, :format=>:csv){|b| buf << b; raise ArgumentError}}.should raise_error(Sequel::DatabaseDisconnectError)
      buf.should == ["1,2\n"]
      buf.clear
      @db.copy_table(:test_copy){|b| buf << b}
      buf.should == ["1\t2\n", "3\t4\n"]
    end

    specify "should work fine when using a block that is terminated early with a following regular query" do
      buf = []
      proc{@db.copy_table(:test_copy, :format=>:csv){|b| buf << b; break}}.should raise_error(Sequel::DatabaseDisconnectError)
      buf.should == ["1,2\n"]
      buf.clear
      proc{@db.copy_table(:test_copy, :format=>:csv){|b| buf << b; raise ArgumentError}}.should raise_error(Sequel::DatabaseDisconnectError)
      buf.should == ["1,2\n"]
      @db[:test_copy].select_order_map(:x).should == [1, 3]
    end
  end

  describe "Postgres::Database LISTEN/NOTIFY" do
    before(:all) do
      @db = POSTGRES_DB
    end

    specify "should support listen and notify" do
      notify_pid = @db.synchronize{|conn| conn.backend_pid}

      called = false
      @db.listen('foo', :after_listen=>proc{@db.notify('foo')}) do |ev, pid, payload|
        ev.should == 'foo'
        pid.should == notify_pid
        ['', nil].should include(payload)
        called = true
      end.should == 'foo'
      called.should be_true

      called = false
      @db.listen('foo', :after_listen=>proc{@db.notify('foo', :payload=>'bar')}) do |ev, pid, payload|
        ev.should == 'foo'
        pid.should == notify_pid
        payload.should == 'bar'
        called = true
      end.should == 'foo'
      called.should be_true

      @db.listen('foo', :after_listen=>proc{@db.notify('foo')}).should == 'foo'

      called = false
      called2 = false
      i = 0
      @db.listen(['foo', 'bar'], :after_listen=>proc{@db.notify('foo', :payload=>'bar'); @db.notify('bar', :payload=>'foo')}, :loop=>proc{i+=1}) do |ev, pid, payload|
        if !called
          ev.should == 'foo'
          pid.should == notify_pid
          payload.should == 'bar'
          called = true
        else
          ev.should == 'bar'
          pid.should == notify_pid
          payload.should == 'foo'
          called2 = true
          break
        end
      end.should be_nil
      called.should be_true
      called2.should be_true
      i.should == 1
    end

    specify "should accept a :timeout option in listen" do
      @db.listen('foo2', :timeout=>0.001).should == nil
      called = false
      @db.listen('foo2', :timeout=>0.001){|ev, pid, payload| called = true}.should == nil
      called.should be_false
      i = 0
      @db.listen('foo2', :timeout=>0.001, :loop=>proc{i+=1; throw :stop if i > 3}){|ev, pid, payload| called = true}.should == nil
      i.should == 4
    end unless RUBY_PLATFORM =~ /mingw/ # Ruby freezes on this spec on this platform/version
  end
end

describe 'PostgreSQL special float handling' do
  before do
    @db = POSTGRES_DB
    @db.create_table!(:test5){Float :value}
    @db.sqls.clear
    @ds = @db[:test5]
  end
  after do
    @db.drop_table?(:test5)
  end

  if check_sqls
    specify 'should quote NaN' do
      nan = 0.0/0.0
      @ds.insert_sql(:value => nan).should == %q{INSERT INTO "test5" ("value") VALUES ('NaN')}
    end

    specify 'should quote +Infinity' do
      inf = 1.0/0.0
      @ds.insert_sql(:value => inf).should == %q{INSERT INTO "test5" ("value") VALUES ('Infinity')}
    end

    specify 'should quote -Infinity' do
      inf = -1.0/0.0
      @ds.insert_sql(:value => inf).should == %q{INSERT INTO "test5" ("value") VALUES ('-Infinity')}
    end
  end

  if POSTGRES_DB.adapter_scheme == :postgres
    specify 'inserts NaN' do
      nan = 0.0/0.0
      @ds.insert(:value=>nan)
      @ds.all[0][:value].nan?.should be_true
    end

    specify 'inserts +Infinity' do
      inf = 1.0/0.0
      @ds.insert(:value=>inf)
      @ds.all[0][:value].infinite?.should > 0
    end

    specify 'inserts -Infinity' do
      inf = -1.0/0.0
      @ds.insert(:value=>inf)
      @ds.all[0][:value].infinite?.should < 0
    end
  end
end

describe 'PostgreSQL array handling' do
  before(:all) do
    Sequel.extension :pg_array
    @db = POSTGRES_DB
    @db.extend Sequel::Postgres::PGArray::DatabaseMethods
    @ds = @db[:items]
    @native = POSTGRES_DB.adapter_scheme == :postgres
    @jdbc = POSTGRES_DB.adapter_scheme == :jdbc
    @tp = lambda{@db.schema(:items).map{|a| a.last[:type]}}
  end
  after do
    @db.drop_table?(:items)
  end

  specify 'insert and retrieve integer and float arrays of various sizes' do
    @db.create_table!(:items) do
      column :i2, 'int2[]'
      column :i4, 'int4[]'
      column :i8, 'int8[]'
      column :r, 'real[]'
      column :dp, 'double precision[]'
    end
    @tp.call.should == [:integer_array, :integer_array, :bigint_array, :float_array, :float_array]
    @ds.insert([1].pg_array(:int2), [nil, 2].pg_array(:int4), [3, nil].pg_array(:int8), [4, nil, 4.5].pg_array(:real), [5, nil, 5.5].pg_array("double precision"))
    @ds.count.should == 1
    rs = @ds.all
    if @jdbc || @native
      rs.should == [{:i2=>[1], :i4=>[nil, 2], :i8=>[3, nil], :r=>[4.0, nil, 4.5], :dp=>[5.0, nil, 5.5]}]
    end
    if @native
      rs.first.values.each{|v| v.should_not be_a_kind_of(Array)}
      rs.first.values.each{|v| v.to_a.should be_a_kind_of(Array)}
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.should == rs
    end

    @ds.delete
    @ds.insert([[1], [2]].pg_array(:int2), [[nil, 2], [3, 4]].pg_array(:int4), [[3, nil], [nil, nil]].pg_array(:int8), [[4, nil], [nil, 4.5]].pg_array(:real), [[5, nil], [nil, 5.5]].pg_array("double precision"))

    rs = @ds.all
    if @jdbc || @native
      rs.should == [{:i2=>[[1], [2]], :i4=>[[nil, 2], [3, 4]], :i8=>[[3, nil], [nil, nil]], :r=>[[4, nil], [nil, 4.5]], :dp=>[[5, nil], [nil, 5.5]]}]
    end
    if @native
      rs.first.values.each{|v| v.should_not be_a_kind_of(Array)}
      rs.first.values.each{|v| v.to_a.should be_a_kind_of(Array)}
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.should == rs
    end
  end

  specify 'insert and retrieve decimal arrays' do
    @db.create_table!(:items) do
      column :n, 'numeric[]'
    end
    @tp.call.should == [:decimal_array]
    @ds.insert([BigDecimal.new('1.000000000000000000001'), nil, BigDecimal.new('1')].pg_array(:numeric))
    @ds.count.should == 1
    rs = @ds.all
    if @jdbc || @native
      rs.should == [{:n=>[BigDecimal.new('1.000000000000000000001'), nil, BigDecimal.new('1')]}]
    end
    if @native
      rs.first.values.each{|v| v.should_not be_a_kind_of(Array)}
      rs.first.values.each{|v| v.to_a.should be_a_kind_of(Array)}
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.should == rs
    end

    @ds.delete
    @ds.insert([[BigDecimal.new('1.0000000000000000000000000000001'), nil], [nil, BigDecimal.new('1')]].pg_array(:numeric))
    rs = @ds.all
    if @jdbc || @native
      rs.should == [{:n=>[[BigDecimal.new('1.0000000000000000000000000000001'), nil], [nil, BigDecimal.new('1')]]}]
    end
    if @native
      rs.first.values.each{|v| v.should_not be_a_kind_of(Array)}
      rs.first.values.each{|v| v.to_a.should be_a_kind_of(Array)}
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.should == rs
    end
  end

  specify 'insert and retrieve string arrays' do
    @db.create_table!(:items) do
      column :c, 'char(4)[]'
      column :vc, 'varchar[]'
      column :t, 'text[]'
    end
    @tp.call.should == [:string_array, :string_array, :string_array]
    @ds.insert(['a', nil, 'NULL', 'b"\'c'].pg_array('char(4)'), ['a', nil, 'NULL', 'b"\'c'].pg_array(:varchar), ['a', nil, 'NULL', 'b"\'c'].pg_array(:text))
    @ds.count.should == 1
    rs = @ds.all
    if @jdbc || @native
      rs.should == [{:c=>['a   ', nil, 'NULL', 'b"\'c'], :vc=>['a', nil, 'NULL', 'b"\'c'], :t=>['a', nil, 'NULL', 'b"\'c']}]
    end
    if @native
      rs.first.values.each{|v| v.should_not be_a_kind_of(Array)}
      rs.first.values.each{|v| v.to_a.should be_a_kind_of(Array)}
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.should == rs
    end

    @ds.delete
    @ds.insert([[['a'], [nil]], [['NULL'], ['b"\'c']]].pg_array('char(4)'), [[['a'], ['']], [['NULL'], ['b"\'c']]].pg_array(:varchar), [[['a'], [nil]], [['NULL'], ['b"\'c']]].pg_array(:text))
    rs = @ds.all
    if @jdbc || @native
      rs.should == [{:c=>[[['a   '], [nil]], [['NULL'], ['b"\'c']]], :vc=>[[['a'], ['']], [['NULL'], ['b"\'c']]], :t=>[[['a'], [nil]], [['NULL'], ['b"\'c']]]}]
    end
    if @native
      rs.first.values.each{|v| v.should_not be_a_kind_of(Array)}
      rs.first.values.each{|v| v.to_a.should be_a_kind_of(Array)}
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.should == rs
    end
  end

  specify 'insert and retrieve arrays of other types' do
    @db.create_table!(:items) do
      column :b, 'bool[]'
      column :d, 'date[]'
      column :t, 'time[]'
      column :ts, 'timestamp[]'
      column :tstz, 'timestamptz[]'
    end
    @tp.call.should == [:boolean_array, :date_array, :time_array, :datetime_array, :datetime_timezone_array]

    d = Date.today
    t = Sequel::SQLTime.create(10, 20, 30)
    ts = Time.local(2011, 1, 2, 3, 4, 5)

    @ds.insert([true, false].pg_array(:bool), [d, nil].pg_array(:date), [t, nil].pg_array(:time), [ts, nil].pg_array(:timestamp), [ts, nil].pg_array(:timestamptz))
    @ds.count.should == 1
    rs = @ds.all
    if @jdbc || @native
      rs.should == [{:b=>[true, false], :d=>[d, nil], :t=>[t, nil], :ts=>[ts, nil], :tstz=>[ts, nil]}]
    end
    if @native
      rs.first.values.each{|v| v.should_not be_a_kind_of(Array)}
      rs.first.values.each{|v| v.to_a.should be_a_kind_of(Array)}
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.should == rs
    end

    @db.create_table!(:items) do
      column :ba, 'bytea[]'
      column :tz, 'timetz[]'
      column :o, 'oid[]'
    end
    @tp.call.should == [:blob_array, :time_timezone_array, :integer_array]
    @ds.insert( [Sequel.blob("a\0"), nil].pg_array(:bytea), [t, nil].pg_array(:timetz), [1, 2, 3].pg_array(:oid))
    @ds.count.should == 1
    if @native
      rs = @ds.all
      rs.should == [{:ba=>[Sequel.blob("a\0"), nil], :tz=>[t, nil], :o=>[1, 2, 3]}]
      rs.first.values.each{|v| v.should_not be_a_kind_of(Array)}
      rs.first.values.each{|v| v.to_a.should be_a_kind_of(Array)}
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.should == rs
    end
  end

  specify 'use arrays in bound variables' do
    @db.create_table!(:items) do
      column :i, 'int4[]'
    end
    @ds.call(:insert, {:i=>[1,2]}, {:i=>:$i})
    @ds.get(:i).should == [1, 2]
    @ds.filter(:i=>:$i).call(:first, :i=>[1,2]).should == {:i=>[1,2]}
    @ds.filter(:i=>:$i).call(:first, :i=>[1,3]).should == nil

    @db.create_table!(:items) do
      column :i, 'text[]'
    end
    a = ["\"\\\\\"{}\n\t\r \v\b123afP", 'NULL', nil, '']
    @ds.call(:insert, {:i=>:$i}, :i=>a.pg_array)
    @ds.get(:i).should == a
    @ds.filter(:i=>:$i).call(:first, :i=>a).should == {:i=>a}
    @ds.filter(:i=>:$i).call(:first, :i=>['', nil, nil, 'a']).should == nil

    @db.create_table!(:items) do
      column :i, 'date[]'
    end
    a = [Date.today]
    @ds.call(:insert, {:i=>:$i}, :i=>a.pg_array('date'))
    @ds.get(:i).should == a
    @ds.filter(:i=>:$i).call(:first, :i=>a).should == {:i=>a}
    @ds.filter(:i=>:$i).call(:first, :i=>[Date.today-1].pg_array('date')).should == nil

    @db.create_table!(:items) do
      column :i, 'timestamp[]'
    end
    a = [Time.local(2011, 1, 2, 3, 4, 5)]
    @ds.call(:insert, {:i=>:$i}, :i=>a.pg_array('timestamp'))
    @ds.get(:i).should == a
    @ds.filter(:i=>:$i).call(:first, :i=>a).should == {:i=>a}
    @ds.filter(:i=>:$i).call(:first, :i=>[a.first-1].pg_array('timestamp')).should == nil

    @db.create_table!(:items) do
      column :i, 'boolean[]'
    end
    a = [true, false]
    @ds.call(:insert, {:i=>:$i}, :i=>a.pg_array('boolean'))
    @ds.get(:i).should == a
    @ds.filter(:i=>:$i).call(:first, :i=>a).should == {:i=>a}
    @ds.filter(:i=>:$i).call(:first, :i=>[false, true].pg_array('boolean')).should == nil

    @db.create_table!(:items) do
      column :i, 'bytea[]'
    end
    a = [Sequel.blob("a\0'\"")]
    @ds.call(:insert, {:i=>:$i}, :i=>a.pg_array('bytea'))
    @ds.get(:i).should == a
    @ds.filter(:i=>:$i).call(:first, :i=>a).should == {:i=>a}
    @ds.filter(:i=>:$i).call(:first, :i=>[Sequel.blob("b\0")].pg_array('bytea')).should == nil
  end if POSTGRES_DB.adapter_scheme == :postgres && SEQUEL_POSTGRES_USES_PG

  specify 'with models' do
    @db.create_table!(:items) do
      primary_key :id
      column :i, 'integer[]'
      column :f, 'double precision[]'
      column :d, 'numeric[]'
      column :t, 'text[]'
    end
    c = Class.new(Sequel::Model(@db[:items]))
    c.plugin :typecast_on_load, :i, :f, :d, :t unless @native
    o = c.create(:i=>[1,2, nil], :f=>[[1, 2.5], [3, 4.5]], :d=>[1, BigDecimal.new('1.000000000000000000001')], :t=>[%w'a b c', ['NULL', nil, '1']])
    o.i.should == [1, 2, nil]
    o.f.should == [[1, 2.5], [3, 4.5]]
    o.d.should == [BigDecimal.new('1'), BigDecimal.new('1.000000000000000000001')]
    o.t.should == [%w'a b c', ['NULL', nil, '1']]
  end

  specify 'operations/functions with pg_array_ops' do
    Sequel.extension :pg_array_ops
    @db.create_table!(:items){column :i, 'integer[]'; column :i2, 'integer[]'; column :i3, 'integer[]'; column :i4, 'integer[]'; column :i5, 'integer[]'}
    @ds.insert([1, 2, 3].pg_array, [2, 1].pg_array, [4, 4].pg_array, [[5, 5], [4, 3]].pg_array, [1, nil, 5].pg_array)

    @ds.get(:i.pg_array > :i3).should be_false
    @ds.get(:i3.pg_array > :i).should be_true

    @ds.get(:i.pg_array >= :i3).should be_false
    @ds.get(:i.pg_array >= :i).should be_true

    @ds.get(:i3.pg_array < :i).should be_false
    @ds.get(:i.pg_array < :i3).should be_true

    @ds.get(:i3.pg_array <= :i).should be_false
    @ds.get(:i.pg_array <= :i).should be_true

    @ds.get({5=>:i.pg_array.any}.sql_expr).should be_false
    @ds.get({1=>:i.pg_array.any}.sql_expr).should be_true

    @ds.get({1=>:i3.pg_array.all}.sql_expr).should be_false
    @ds.get({4=>:i3.pg_array.all}.sql_expr).should be_true

    @ds.get(:i2.pg_array[1]).should == 2
    @ds.get(:i2.pg_array[2]).should == 1

    @ds.get(:i4.pg_array[2][1]).should == 4
    @ds.get(:i4.pg_array[2][2]).should == 3

    @ds.get(:i.pg_array.contains(:i2)).should be_true
    @ds.get(:i.pg_array.contains(:i3)).should be_false

    @ds.get(:i2.pg_array.contained_by(:i)).should be_true
    @ds.get(:i.pg_array.contained_by(:i2)).should be_false

    @ds.get(:i.pg_array.overlaps(:i2)).should be_true
    @ds.get(:i2.pg_array.overlaps(:i3)).should be_false

    @ds.get(:i.pg_array.dims).should == '[1:3]'
    @ds.get(:i.pg_array.length).should == 3
    @ds.get(:i.pg_array.lower).should == 1

    if @db.server_version >= 90000
      @ds.get(:i5.pg_array.join).should == '15'
      @ds.get(:i5.pg_array.join(':')).should == '1:5'
      @ds.get(:i5.pg_array.join(':', '*')).should == '1:*:5'
    end
    @ds.select(:i.pg_array.unnest).from_self.count.should == 3 if @db.server_version >= 80400

    if @native
      @ds.get(:i.pg_array.push(4)).should == [1, 2, 3, 4]
      @ds.get(:i.pg_array.unshift(4)).should == [4, 1, 2, 3]
      @ds.get(:i.pg_array.concat(:i2)).should == [1, 2, 3, 2, 1]
    end
  end
end

describe 'PostgreSQL hstore handling' do
  before(:all) do
    Sequel.extension :pg_hstore
    @db = POSTGRES_DB
    @db.extend Sequel::Postgres::HStore::DatabaseMethods
    @ds = @db[:items]
    @h = {'a'=>'b', 'c'=>nil, 'd'=>'NULL', 'e'=>'\\\\" \\\' ,=>'}
    @native = POSTGRES_DB.adapter_scheme == :postgres
  end
  after do
    @db.drop_table?(:items)
  end

  specify 'insert and retrieve hstore values' do
    @db.create_table!(:items) do
      column :h, :hstore
    end
    @ds.insert(@h.hstore)
    @ds.count.should == 1
    if @native
      rs = @ds.all
      v = rs.first[:h]
      v.should_not be_a_kind_of(Hash)
      v.to_hash.should be_a_kind_of(Hash)
      v.to_hash.should == @h
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.should == rs
    end
  end

  specify 'use hstore in bound variables' do
    @db.create_table!(:items) do
      column :i, :hstore
    end
    @ds.call(:insert, {:i=>@h.hstore}, {:i=>:$i})
    @ds.get(:i).should == @h
    @ds.filter(:i=>:$i).call(:first, :i=>@h.hstore).should == {:i=>@h}
    @ds.filter(:i=>:$i).call(:first, :i=>{}.hstore).should == nil

    @ds.delete
    @ds.call(:insert, {:i=>@h}, {:i=>:$i})
    @ds.get(:i).should == @h
    @ds.filter(:i=>:$i).call(:first, :i=>@h).should == {:i=>@h}
    @ds.filter(:i=>:$i).call(:first, :i=>{}).should == nil
  end if POSTGRES_DB.adapter_scheme == :postgres && SEQUEL_POSTGRES_USES_PG

  specify 'with models' do
    @db.create_table!(:items) do
      primary_key :id
      column :h, :hstore
    end
    c = Class.new(Sequel::Model(@db[:items]))
    c.plugin :typecast_on_load, :h unless @native
    c.create(:h=>@h.hstore).h.should == @h
  end

  specify 'operations/functions with pg_hstore_ops' do
    Sequel.extension :pg_hstore_ops
    Sequel.extension :pg_array
    Sequel.extension :pg_array_ops
    @db.create_table!(:items){hstore :h1; hstore :h2; hstore :h3; String :t}
    @ds.insert({'a'=>'b', 'c'=>nil}.hstore, {'a'=>'b'}.hstore, {'d'=>'e'}.hstore)
    h1 = :h1.hstore
    h2 = :h2.hstore
    h3 = :h3.hstore
    
    @ds.get(h1['a']).should == 'b'
    @ds.get(h1['d']).should == nil

    @ds.get(h2.concat(h3).keys.pg_array.length).should == 2
    @ds.get(h1.concat(h3).keys.pg_array.length).should == 3
    @ds.get(h2.merge(h3).keys.pg_array.length).should == 2
    @ds.get(h1.merge(h3).keys.pg_array.length).should == 3

    unless @db.adapter_scheme == :do
      # Broken DataObjects thinks operators with ? represent placeholders
      @ds.get(h1.contain_all(%w'a c'.pg_array)).should == true
      @ds.get(h1.contain_all(%w'a d'.pg_array)).should == false

      @ds.get(h1.contain_any(%w'a d'.pg_array)).should == true
      @ds.get(h1.contain_any(%w'e d'.pg_array)).should == false
    end

    @ds.get(h1.contains(h2)).should == true
    @ds.get(h1.contains(h3)).should == false

    @ds.get(h2.contained_by(h1)).should == true
    @ds.get(h2.contained_by(h3)).should == false

    @ds.get(h1.defined('a')).should == true
    @ds.get(h1.defined('c')).should == false
    @ds.get(h1.defined('d')).should == false

    @ds.get(h1.delete('a')['c']).should == nil
    @ds.get(h1.delete(%w'a d'.pg_array)['c']).should == nil
    @ds.get(h1.delete(h2)['c']).should == nil

    @ds.from({'a'=>'b', 'c'=>nil}.hstore.op.each).order(:key).all.should == [{:key=>'a', :value=>'b'}, {:key=>'c', :value=>nil}]

    unless @db.adapter_scheme == :do
      @ds.get(h1.has_key?('c')).should == true
      @ds.get(h1.include?('c')).should == true
      @ds.get(h1.key?('c')).should == true
      @ds.get(h1.member?('c')).should == true
      @ds.get(h1.exist?('c')).should == true
      @ds.get(h1.has_key?('d')).should == false
      @ds.get(h1.include?('d')).should == false
      @ds.get(h1.key?('d')).should == false
      @ds.get(h1.member?('d')).should == false
      @ds.get(h1.exist?('d')).should == false
    end

    @ds.get(h1.hstore.hstore.hstore.keys.pg_array.length).should == 2
    @ds.get(h1.keys.pg_array.length).should == 2
    @ds.get(h2.keys.pg_array.length).should == 1
    @ds.get(h1.akeys.pg_array.length).should == 2
    @ds.get(h2.akeys.pg_array.length).should == 1

    @ds.from({'t'=>'s'}.hstore.op.populate(Sequel::SQL::Cast.new(nil, :items))).select_map(:t).should == ['s']
    @ds.from(:items___i).select({'t'=>'s'}.hstore.op.record_set(:i).as(:r)).from_self(:alias=>:s).select('(r).*'.lit).from_self.select_map(:t).should == ['s']

    @ds.from({'t'=>'s', 'a'=>'b'}.hstore.op.skeys.as(:s)).select_order_map(:s).should == %w'a t'

    @ds.get(h1.slice(%w'a c'.pg_array).keys.pg_array.length).should == 2
    @ds.get(h1.slice(%w'd c'.pg_array).keys.pg_array.length).should == 1
    @ds.get(h1.slice(%w'd e'.pg_array).keys.pg_array.length).should == nil

    @ds.from({'t'=>'s', 'a'=>'b'}.hstore.op.svals.as(:s)).select_order_map(:s).should == %w'b s'

    @ds.get(h1.to_array.pg_array.length).should == 4
    @ds.get(h2.to_array.pg_array.length).should == 2

    @ds.get(h1.to_matrix.pg_array.length).should == 2
    @ds.get(h2.to_matrix.pg_array.length).should == 1

    @ds.get(h1.values.pg_array.length).should == 2
    @ds.get(h2.values.pg_array.length).should == 1
    @ds.get(h1.avals.pg_array.length).should == 2
    @ds.get(h2.avals.pg_array.length).should == 1
  end
end if POSTGRES_DB.type_supported?(:hstore)

describe 'PostgreSQL json type' do
  before(:all) do
    Sequel.extension :pg_array, :pg_json
    @db = POSTGRES_DB
    @db.extend Sequel::Postgres::PGArray::DatabaseMethods
    @db.extend Sequel::Postgres::JSONDatabaseMethods
    @ds = @db[:items]
    @a = [1, 2, {'a'=>'b'}, 3.0]
    @h = {'a'=>'b', '1'=>[3, 4, 5]}
    @native = POSTGRES_DB.adapter_scheme == :postgres
  end
  after do
    @db.drop_table?(:items)
  end

  specify 'insert and retrieve json values' do
    @db.create_table!(:items){json :j}
    @ds.insert(@h.pg_json)
    @ds.count.should == 1
    if @native
      rs = @ds.all
      v = rs.first[:j]
      v.should_not be_a_kind_of(Hash)
      v.to_hash.should be_a_kind_of(Hash)
      v.should == @h
      v.to_hash.should == @h
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.should == rs
    end

    @ds.delete
    @ds.insert(@a.pg_json)
    @ds.count.should == 1
    if @native
      rs = @ds.all
      v = rs.first[:j]
      v.should_not be_a_kind_of(Array)
      v.to_a.should be_a_kind_of(Array)
      v.should == @a
      v.to_a.should == @a
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.should == rs
    end
  end

  specify 'insert and retrieve json[] values' do
    @db.create_table!(:items){column :j, 'json[]'}
    j = [{'a'=>1}.pg_json, ['b', 2].pg_json].pg_array
    @ds.insert(j)
    @ds.count.should == 1
    if @native
      rs = @ds.all
      v = rs.first[:j]
      v.should_not be_a_kind_of(Array)
      v.to_a.should be_a_kind_of(Array)
      v.should == j
      v.to_a.should == j
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.should == rs
    end
  end

  specify 'use json in bound variables' do
    @db.create_table!(:items){json :i}
    @ds.call(:insert, {:i=>@h.pg_json}, {:i=>:$i})
    @ds.get(:i).should == @h
    @ds.filter(:i.cast(String)=>:$i).call(:first, :i=>@h.pg_json).should == {:i=>@h}
    @ds.filter(:i.cast(String)=>:$i).call(:first, :i=>{}.pg_json).should == nil
    @ds.filter(:i.cast(String)=>:$i).call(:delete, :i=>@h.pg_json).should == 1

    @ds.call(:insert, {:i=>@a.pg_json}, {:i=>:$i})
    @ds.get(:i).should == @a
    @ds.filter(:i.cast(String)=>:$i).call(:first, :i=>@a.pg_json).should == {:i=>@a}
    @ds.filter(:i.cast(String)=>:$i).call(:first, :i=>[].pg_json).should == nil

    @db.create_table!(:items){column :i, 'json[]'}
    j = [{'a'=>1}.pg_json, ['b', 2].pg_json].pg_array(:text)
    @ds.call(:insert, {:i=>j}, {:i=>:$i})
    @ds.get(:i).should == j
    @ds.filter(:i.cast('text[]')=>:$i).call(:first, :i=>j).should == {:i=>j}
    @ds.filter(:i.cast('text[]')=>:$i).call(:first, :i=>[].pg_array).should == nil
  end if POSTGRES_DB.adapter_scheme == :postgres && SEQUEL_POSTGRES_USES_PG

  specify 'with models' do
    @db.create_table!(:items) do
      primary_key :id
      json :h
    end
    c = Class.new(Sequel::Model(@db[:items]))
    c.plugin :typecast_on_load, :h unless @native
    c.create(:h=>@h.pg_json).h.should == @h
    c.create(:h=>@a.pg_json).h.should == @a
  end
end if POSTGRES_DB.server_version >= 90200

describe 'PostgreSQL inet/cidr types' do
  ipv6_broken = (IPAddr.new('::1'); false) rescue true

  before(:all) do
    Sequel.extension :pg_array, :pg_inet
    @db = POSTGRES_DB
    @db.extend Sequel::Postgres::PGArray::DatabaseMethods
    @db.extend Sequel::Postgres::InetDatabaseMethods
    @ds = @db[:items]
    @v4 = '127.0.0.1'
    @v4nm = '127.0.0.0/8'
    @v6 = '2001:4f8:3:ba:2e0:81ff:fe22:d1f1'
    @v6nm = '2001:4f8:3:ba::/64'
    @ipv4 = IPAddr.new(@v4)
    @ipv4nm = IPAddr.new(@v4nm)
    unless ipv6_broken
      @ipv6 = IPAddr.new(@v6)
      @ipv6nm = IPAddr.new(@v6nm)
    end
    @native = POSTGRES_DB.adapter_scheme == :postgres
  end
  after do
    @db.drop_table?(:items)
  end

  specify 'insert and retrieve inet/cidr values' do
    @db.create_table!(:items){inet :i; cidr :c}
    @ds.insert(@ipv4, @ipv4nm)
    @ds.count.should == 1
    if @native
      rs = @ds.all
      rs.first[:i].should == @ipv4
      rs.first[:c].should == @ipv4nm
      rs.first[:i].should be_a_kind_of(IPAddr)
      rs.first[:c].should be_a_kind_of(IPAddr)
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.should == rs
    end

    unless ipv6_broken
      @ds.delete
      @ds.insert(@ipv6, @ipv6nm)
      @ds.count.should == 1
      if @native
        rs = @ds.all
        v = rs.first[:j]
        rs.first[:i].should == @ipv6
        rs.first[:c].should == @ipv6nm
        rs.first[:i].should be_a_kind_of(IPAddr)
        rs.first[:c].should be_a_kind_of(IPAddr)
        @ds.delete
        @ds.insert(rs.first)
        @ds.all.should == rs
      end
    end
  end

  specify 'insert and retrieve inet/cidr/macaddr array values' do
    @db.create_table!(:items){column :i, 'inet[]'; column :c, 'cidr[]'; column :m, 'macaddr[]'}
    @ds.insert([@ipv4].pg_array('inet'), [@ipv4nm].pg_array('cidr'), ['12:34:56:78:90:ab'].pg_array('macaddr'))
    @ds.count.should == 1
    if @native
      rs = @ds.all
      rs.first.values.all?{|c| c.is_a?(Sequel::Postgres::PGArray)}.should be_true
      rs.first[:i].first.should == @ipv4
      rs.first[:c].first.should == @ipv4nm
      rs.first[:m].first.should == '12:34:56:78:90:ab'
      rs.first[:i].first.should be_a_kind_of(IPAddr)
      rs.first[:c].first.should be_a_kind_of(IPAddr)
      @ds.delete
      @ds.insert(rs.first)
      @ds.all.should == rs
    end
  end

  specify 'use ipaddr in bound variables' do
    @db.create_table!(:items){inet :i; cidr :c}

    @ds.call(:insert, {:i=>@ipv4, :c=>@ipv4nm}, {:i=>:$i, :c=>:$c})
    @ds.get(:i).should == @ipv4
    @ds.get(:c).should == @ipv4nm
    @ds.filter(:i=>:$i, :c=>:$c).call(:first, :i=>@ipv4, :c=>@ipv4nm).should == {:i=>@ipv4, :c=>@ipv4nm}
    @ds.filter(:i=>:$i, :c=>:$c).call(:first, :i=>@ipv6, :c=>@ipv6nm).should == nil
    @ds.filter(:i=>:$i, :c=>:$c).call(:delete, :i=>@ipv4, :c=>@ipv4nm).should == 1

    unless ipv6_broken
      @ds.call(:insert, {:i=>@ipv6, :c=>@ipv6nm}, {:i=>:$i, :c=>:$c})
      @ds.get(:i).should == @ipv6
      @ds.get(:c).should == @ipv6nm
      @ds.filter(:i=>:$i, :c=>:$c).call(:first, :i=>@ipv6, :c=>@ipv6nm).should == {:i=>@ipv6, :c=>@ipv6nm}
      @ds.filter(:i=>:$i, :c=>:$c).call(:first, :i=>@ipv4, :c=>@ipv4nm).should == nil
      @ds.filter(:i=>:$i, :c=>:$c).call(:delete, :i=>@ipv6, :c=>@ipv6nm).should == 1
    end

    @db.create_table!(:items){column :i, 'inet[]'; column :c, 'cidr[]'; column :m, 'macaddr[]'}
    @ds.call(:insert, {:i=>[@ipv4], :c=>[@ipv4nm], :m=>['12:34:56:78:90:ab']}, {:i=>:$i, :c=>:$c, :m=>:$m})
    @ds.filter(:i=>:$i, :c=>:$c, :m=>:$m).call(:first, :i=>[@ipv4], :c=>[@ipv4nm], :m=>['12:34:56:78:90:ab']).should == {:i=>[@ipv4], :c=>[@ipv4nm], :m=>['12:34:56:78:90:ab']}
    @ds.filter(:i=>:$i, :c=>:$c, :m=>:$m).call(:first, :i=>[], :c=>[], :m=>[]).should == nil
    @ds.filter(:i=>:$i, :c=>:$c, :m=>:$m).call(:delete, :i=>[@ipv4], :c=>[@ipv4nm], :m=>['12:34:56:78:90:ab']).should == 1
  end if POSTGRES_DB.adapter_scheme == :postgres && SEQUEL_POSTGRES_USES_PG

  specify 'with models' do
    @db.create_table!(:items) do
      primary_key :id
      inet :i
      cidr :c
    end
    c = Class.new(Sequel::Model(@db[:items]))
    c.plugin :typecast_on_load, :i, :c unless @native
    c.create(:i=>@v4, :c=>@v4nm).values.values_at(:i, :c).should == [@ipv4, @ipv4nm]
    unless ipv6_broken
      c.create(:i=>@ipv6, :c=>@ipv6nm).values.values_at(:i, :c).should == [@ipv6, @ipv6nm]
    end
  end
end

describe 'PostgreSQL range types' do
  before(:all) do
    Sequel.extension :pg_array, :pg_range
    @db = POSTGRES_DB
    @db.extend Sequel::Postgres::PGArray::DatabaseMethods
    @db.extend Sequel::Postgres::PGRange::DatabaseMethods
    @ds = @db[:items]
    @map = {:i4=>'int4range', :i8=>'int8range', :n=>'numrange', :d=>'daterange', :t=>'tsrange', :tz=>'tstzrange'}
    @r = {:i4=>1...2, :i8=>2...3, :n=>BigDecimal.new('1.0')..BigDecimal.new('2.0'), :d=>Date.today...(Date.today+1), :t=>Time.local(2011, 1)..Time.local(2011, 2), :tz=>Time.local(2011, 1)..Time.local(2011, 2)}
    @ra = {}
    @pgr = {}
    @pgra = {}
    @r.each{|k, v| @ra[k] = [v].pg_array(@map[k])}
    @r.each{|k, v| @pgr[k] = v.pg_range}
    @r.each{|k, v| @pgra[k] = [v.pg_range].pg_array(@map[k])}
    @native = POSTGRES_DB.adapter_scheme == :postgres
  end
  after do
    @db.drop_table?(:items)
  end

  specify 'insert and retrieve range type values' do
    @db.create_table!(:items){int4range :i4; int8range :i8; numrange :n; daterange :d; tsrange :t; tstzrange :tz}
    [@r, @pgr].each do |input|
      h = {}
      input.each{|k, v| h[k] = Sequel.cast(v, @map[k])}
      @ds.insert(h)
      @ds.count.should == 1
      if @native
        rs = @ds.all
        rs.first.each do |k, v|
          v.should_not be_a_kind_of(Range)
          v.to_range.should be_a_kind_of(Range)
          v.should == @r[k]
          v.to_range.should == @r[k]
        end
        @ds.delete
        @ds.insert(rs.first)
        @ds.all.should == rs
      end
      @ds.delete
    end
  end

  specify 'insert and retrieve arrays of range type values' do
    @db.create_table!(:items){column :i4, 'int4range[]'; column :i8, 'int8range[]'; column :n, 'numrange[]'; column :d, 'daterange[]'; column :t, 'tsrange[]'; column :tz, 'tstzrange[]'}
    [@ra, @pgra].each do |input|
      @ds.insert(input)
      @ds.count.should == 1
      if @native
        rs = @ds.all
        rs.first.each do |k, v|
          v.should_not be_a_kind_of(Array)
          v.to_a.should be_a_kind_of(Array)
          v.first.should_not be_a_kind_of(Range)
          v.first.to_range.should be_a_kind_of(Range)
          v.should == @ra[k].to_a
          v.first.should == @r[k]
        end
        @ds.delete
        @ds.insert(rs.first)
        @ds.all.should == rs
      end
      @ds.delete
    end
  end

  specify 'use range types in bound variables' do
    @db.create_table!(:items){int4range :i4; int8range :i8; numrange :n; daterange :d; tsrange :t; tstzrange :tz}
    h = {}
    @r.keys.each{|k| h[k] = :"$#{k}"}
    r2 = {}
    @r.each{|k, v| r2[k] = Range.new(v.begin, v.end+2)}
    @ds.call(:insert, @r, h)
    @ds.first.should == @r
    @ds.filter(h).call(:first, @r).should == @r
    @ds.filter(h).call(:first, @pgr).should == @r
    @ds.filter(h).call(:first, r2).should == nil
    @ds.filter(h).call(:delete, @r).should == 1

    @db.create_table!(:items){column :i4, 'int4range[]'; column :i8, 'int8range[]'; column :n, 'numrange[]'; column :d, 'daterange[]'; column :t, 'tsrange[]'; column :tz, 'tstzrange[]'}
    @r.each{|k, v| r2[k] = [Range.new(v.begin, v.end+2)]}
    @ds.call(:insert, @ra, h)
    @ds.filter(h).call(:first, @ra).each{|k, v| v.should == @ra[k].to_a}
    @ds.filter(h).call(:first, @pgra).each{|k, v| v.should == @ra[k].to_a}
    @ds.filter(h).call(:first, r2).should == nil
    @ds.filter(h).call(:delete, @ra).should == 1
  end if POSTGRES_DB.adapter_scheme == :postgres && SEQUEL_POSTGRES_USES_PG

  specify 'with models' do
    @db.create_table!(:items){primary_key :id; int4range :i4; int8range :i8; numrange :n; daterange :d; tsrange :t; tstzrange :tz}
    c = Class.new(Sequel::Model(@db[:items]))
    c.plugin :typecast_on_load, :i4, :i8, :n, :d, :t, :tz unless @native
    v = c.create(@r).values
    v.delete(:id)
    v.should == @r

    unless @db.adapter_scheme == :jdbc
      @db.create_table!(:items){primary_key :id; column :i4, 'int4range[]'; column :i8, 'int8range[]'; column :n, 'numrange[]'; column :d, 'daterange[]'; column :t, 'tsrange[]'; column :tz, 'tstzrange[]'}
      c = Class.new(Sequel::Model(@db[:items]))
      c.plugin :typecast_on_load, :i4, :i8, :n, :d, :t, :tz unless @native
      v = c.create(@ra).values
      v.delete(:id)
      v.each{|k,v| v.should == @ra[k].to_a}
    end
  end
end if POSTGRES_DB.server_version >= 90200

