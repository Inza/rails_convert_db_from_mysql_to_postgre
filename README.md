# convert.rake

Rake task to convert and transfer a Rails database from Postgres to MySQL.

> This fork is compatible with Rails 5, STI and join tables.

The task deletes all data in the development database and then
transfers the data from the production database (in MySQL) into the development
database (in PostgreSQL).

## Features

* Compatible with Rails 5 (and Arel 7.1.2)
* Supports STI tables (with type column)
* Supports M:N join tables (without id)
* Nice to RAM on large data sets
* Works with blobs

## Assumptions

* No writes are happening to either database for the duration of this task
* Both schemas are identical (i.e. migrations are at the same VERSION)
* The data in development DB can be removed and replaced

## Usage

1. Place convert.rake in your lib/tasks directory
2. Setup your `database.yml` in a way that:
   - your production will be MySQL DB from where you want to export data (with the date)
   - your development will be PostgreSQL DB to where you want to import data
3. Migrate both DBs to a current schema
   - For production we will just migrate: `RAILS_ENV="production" ./bin/rake db:migrate`
   - For development we can reset: `rake db:drop && rake db:create && rake db:migrate`
4. Run with `rake db:convert:mysql2postgre`
