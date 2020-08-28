```

title: Streaming bigger amounts of data from snowflake in Ruby
published: false
description: How to stream data from Snowflake in Ruby
tags: ruby, snowflake, sql, odbc, jvm

```

## Background

At the company I work for we use ruby as the main language for data import/export jobs.
Many years ago we standardaised on [kiba gem](https://github.com/thbar/kiba) and build an internal project around its main concepts.

About a year ago we migrated to [Snowflake DB](https://www.snowflake.com/) as our main data warehouse.

To connect to Snowflake we use:

- [snowflake odbc driver](https://docs.snowflake.com/en/user-guide/odbc.html)
- [ruby-odbc gem](https://github.com/larskanis/ruby-odbc)
- [sequel gem](https://github.com/jeremyevans/sequel)

To execute some simple quieries it works just fine, but recently I noticed its big shortcoming.

I had to unalod a few millions of records and to my suprise, I didn't see any results for quite a bit in the destination.
Afer a while I understood it's because it loads the whole result set into memory and then it yields the result back to the caller.

Just a quick example what I mean by that:

```ruby
connection = get_snowflake_con
connection["select * from table limit 100000"].each do |record|
  # it doesn't print anything until everything is loaded fro
  puts record
end
```

For any other modern DB connection you would see results as quick as dataset is returned and you could stream it.
If the data is loaded first to memory, then it means that:

- we can get OOM errors
- it's slow as you have "eager" load instead of the stream of data

When I found it out I asked some team members whether they have noticed that and is there fix?
No one really could tell me and everyone assumed it's because of old ruby-odbc driver.

Alright, pretty strange, but I want to fix it as I have a few GBs of data to unlaod to some FTP and I don't want the job to OOM on me.
I started exploring options.

## Approaches

### Approach 1 - paged_each

I checked sequel's docs, thinking there has to be something I could use as an alternative and I found `paged_each`.
It looked like a valid alternative.

https://www.rubydoc.info/github/jeremyevans/sequel/Sequel%2FDataset:paged_each

I gave it a spin,

```ruby
dataset = snowflake
  .connection
  .dataset
  .with_sql("SELECT * FROM big_table order by updated_at")
  .order(:updated_at)

dataset.paged_each(:rows_per_fetch=>10000) do |record|
  puts record
end
```

but:

- it uses `limit`, `offset` kind of pagination so there were many queries to DB and it was slow
- I somehow got duplicates in the returned data

At this point I was quite fed up with ruby, and though of another way.


### Approach 2 - External JVM process

Kiba gem is flexible, so I though I will ask it to execute a JVM process that would stream the results to STDOUT in JSON and ruby would just parse it.
That would be quite generic solution and we could re-use it for other jobs as well.

Some time ago I learnt that Snowflake can unlaod data to inernal stage, and then you can stream the data with JDBC driver. I assumed that it might be quite performant way to get a big amount of data from Snowflake. Here's a bit more details about the solution https://docs.snowflake.com/en/user-guide/data-unload-snowflake.html

I spent few hours and I created a new project, called it `snowflake-to-stdout`. sources here: [sparrovv/snowflake-to-stdout](https://github.com/sparrovv/snowflake-to-stdout)

Quick usage example:

```shell
java -jar snowflake-to-stdout.jar \
  --sql SELECT object_construct(*) FROM big_table \
  --stage stage-name
```

And this would stream [newline delimited JSON](http://ndjson.org/) to SDOUT.

In ruby I creaed a simple utility module that calls whatever command I want, reads the stdout and yields to the caller, I was mainly inspired by this solution: .....

This approach worked fine and was quite performant.

I wasn't happy though that I need to maintain now more code.

### Approach 2.1 - stream JDBC resultsets

At this point I was wondering whether the complexity of unloading to internal stage and streaming is worth the effort. I also noticed that I need to make sure that files are streamed in order, so though let's check how standard JDBC's results performs.

I added an option to  `snowflake-to-stdout` to verify the perofrmance

```bash
java -jar snowflake-unloader.jar \
  --sql SELECT object_construct(*)::varchar FROM big_table \
  --result-set
```

I ran a quick comparison. I unloaded 1M of records from the same table, and measured the time.

The difference was marginal in favour of the approach 2.0 where it streamed files from the stage.

### Approach 3.0 - ruby odbc

I've almost wrapped up the whole story, but then I asked myself. Why this doesn't work in ruby?

I've gone back to the orignal src code and decided to use ruby-odbc driver directly without Sequel gem. Thankfully in the repo there were some examples how to use it:

```ruby
connection = ::ODBC
                 .connect("snowflake", ENV.fetch("SNOWFLAKE_USER"), ENV.fetch("SNOWFLAKE_PASSWORD"))

query = connection
            .prepare("SELECT * from big_table")

query.execute.each_hash(:key=>:Symbol) do |record|
  puts record
end
```

This works as expected. And it's not Streams the results, yay! So all that time the problem was in Sequel :thinking:

### Approach 4.0 - Patching Sequel

Ok so it works with ruby-odbc, why doesn't it then work with ODBC + Sequel gem?
I did what I should have done at the first step, I checked the Sequel sources.

It turned out that the odbc-adapter in Sequel was calling `find_all` before yielding any results back to the caller.

I asked on the mailing group whether there's any specific reason for that behaviour, but no one knew, but they were happy to merge a patch if I provide one. I oppened a [two lines PR](https://github.com/jeremyevans/sequel/pull/1711) which was quickly accepted.

## Comparison

Just for the sake of making it clear how long it takes for a given solution to stream 1M records from Snowflake to my **localhost**, once snowflake already cached the results internally. Please don't take this benchmark seriously becasue it's bound to my broadband connection and it could varried at times.

The query:

 `SELECT construct_object(*)::varchar as JSON FROM big_table limit 1000000`

snowflake-to-sdout

```shell
 time ./target/jars/snowflake-to-stdout --sql "SELECT construct_object(*)::varchar as JSON FROM big_table limit 1000000" > result.json

./target/jars/snowflake-to-stdout --sql  > foo1.json  16.89s user 10.51s system 15% cpu

2:51.30 total
```

snowflake-to-stdout copy-to-stage & stream

```shell
time ./target/jars/snowflake-to-stdout --stage "test" --prefix "new/foo" --keep --sql "SELECT construct_object(*) FROM big_table limit 1000000" > result.json

./target/jars/snowflake-to-stdout --stage "test" --prefix "new/foo" --keep  21.14s user 11.68s system 15% cpu

3:32.49 total
```

Only streaming the data that was already in the stage

```shell
$ time ./target/jars/snowflake-to-stdout --stage "test" --prefix "new/foo" --keep --only-stream > result.json

./target/jars/snowflake-to-stdout --stage "test" --prefix "new/foo" --keep  22.22s user 13.84s system 43% cpu

1:23.83 total
```

ruby sequel / odbc

```shell
time bundle exec ruby ./script/test_snowflake > result.json
bundle exec ruby ./script/test_snowflake_paged > foobar.json  27.45s user 4.79s system 36% cpu

1:27.38 total
```

As I mentioned before, it's not a benchmark. Just a loose comparison to find out what are the figures in my localhost.

## Conclusion

A path to a simple solution is a long one.

I shouldn't have doubt that something that standard like querying and streaming results from DB doesn't work in ruby, but I did.

I've created a new project, wrote many lines of code just to circle back and look at the source of the problem.
