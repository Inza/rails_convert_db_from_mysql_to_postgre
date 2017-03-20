#
# Convert/transfer data from production => development.    This facilitates
# a conversion one database adapter type to another (say postgres -> mysql)
#
# WARNING 1: this script deletes all development data and replaces it with
#            production data
#
# WARNING 2: This script assumes it is the only user updating either database.
#            Database integrity could be corrupted if other users where
#            writing to the databases.
#
# Usage:  rake db:convert:prod2dev
#
# It assumes the development database has a schema identical to the production
# database, but will delete any data before importing the production data
#
# A couple of the outer loops evolved from
#    http://snippets.dzone.com/posts/show/3393
#
# For further instructions see
#    http://myutil.com/2008/8/31/rake-task-transfer-rails-database-mysql-to-postgres
#
# The master repository for this script is at github:
#    http://github.com/face/rails_db_convert_using_adapters/tree/master
#
# Author: Rama McIntosh
#         Matson Systems, Inc.
#         http://www.matsonsystems.com
#
# This rake task is released under this BSD license:
#
# Copyright (c) 2008, Matson Systems, Inc. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
# * Redistributions of source code must retain the above copyright
#   notice, this list of conditions and the following disclaimer.
# * Redistributions in binary form must reproduce the above copyright
#   notice, this list of conditions and the following disclaimer in the
#   documentation and/or other materials provided with the distribution.
# * Neither the name of Matson Systems, Inc. nor the names of its
#   contributors may be used to endorse or promote products derived
#   from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
# FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
# COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
# BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
# ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.


# ------------------------------------------------------------------------------------------
# Adjusted to support Rails 5, STI and M:N join tables by:
#
# - Tomas Jukin <tomas.jukin@juicymo.cz>
# - https://github.com/Inza
#
# See for https://github.com/Inza/rails_convert_db_from_mysql_to_postgre for the latest fork
# ------------------------------------------------------------------------------------------


# ------------------------------------------------------------------------------------------
# USAGE:
#
# 1) Place convert.rake in your lib/tasks directory
# 2) Setup your `database.yml` in a way that:
#    - your production will be MySQL DB from where you want to export data (with the date)
#    - your development will be PostgreSQL DB to where you want to import data
# 3) Migrate both DBs to a current schema
#    - For production we will just migrate: `RAILS_ENV="production" ./bin/rake db:migrate`
#    - For development we can reset: `rake db:drop && rake db:create && rake db:migrate`
# 4) Run with `rake db:convert:mysql2postgre`
#
# ------------------------------------------------------------------------------------------

# PAGE_SIZE is the number of rows updated in a single transaction.
# This facilitates tables where the number of rows exceeds the systems memory
PAGE_SIZE=10000

namespace :db do
  namespace :convert do
    desc 'Convert/import production data to development (from MySQL to PostgreSQL).   DANGER Deletes all data in the development database.   Assumes both schemas are already migrated.'
    task :mysql2postgre => :environment do
      # We need unique classes so ActiveRecord can hash different connections
      # We do not want to use the real Model classes because any business
      # rules will likely get in the way of a database transfer
      class ProductionModelClass < ActiveRecord::Base
      end
      class DevelopmentModelClass < ActiveRecord::Base
      end

      # Silence Arel warning (this rake task needs Arel < 8.0, rake task was tested with Arel 7.1.2)
      $arel_silence_type_casting_deprecation = true

      def rename_type_column(table_name, from, to)
        # mysql syntax
        ProductionModelClass.connection.execute("ALTER TABLE `#{table_name}` CHANGE COLUMN `#{from}` `#{to}` VARCHAR(255) NOT NULL;")
        # postgre syntax
        DevelopmentModelClass.connection.execute("ALTER TABLE #{table_name} RENAME COLUMN #{from} TO #{to};")
      end

      skip_tables = ["schema_info", "schema_migrations", "ar_internal_metadata"]
      ActiveRecord::Base.establish_connection(:production)
      (ActiveRecord::Base.connection.tables - skip_tables).each do |table_name|
        if Rails::VERSION::MAJOR >= 4
          ProductionModelClass.table_name = table_name
          DevelopmentModelClass.table_name = table_name
        else
          ProductionModelClass.set_table_name(table_name)
          DevelopmentModelClass.set_table_name(table_name)
        end

        DevelopmentModelClass.establish_connection(:development)

        if ProductionModelClass.column_names.include? 'type'
          # Rename type columns to typex to bypass STI
          rename_type_column(table_name, 'type', 'typex')
        end

        DevelopmentModelClass.reset_column_information
        ProductionModelClass.reset_column_information
        DevelopmentModelClass.record_timestamps = false

        # Page through the data in case the table is too large to fit in RAM
        offset = count = 0;
        print "Converting #{table_name}..."; STDOUT.flush

        # First, delete any old dev data
        DevelopmentModelClass.delete_all
        DevelopmentModelClass.connection.execute("TRUNCATE #{table_name} RESTART IDENTITY")

        while ((models = ProductionModelClass.all.offset(offset).limit(PAGE_SIZE)).size > 0)
          count += models.size
          offset += PAGE_SIZE

          # Now, write out the prod data to the dev db
          DevelopmentModelClass.transaction do
            models.each do |model|
              attributes = model.attributes
              if DevelopmentModelClass.column_names.include? 'id' # for normal models (with id)
                new_model = DevelopmentModelClass.new(attributes)

                new_model.id = model.id

                if Rails::VERSION::MAJOR >= 4
                  new_model.save(:validate => false)
                else
                  new_model.save(false)
                end
              else # for M:N join tables (without id)
                attributes.delete('id')

                new_model = DevelopmentModelClass.new(attributes)

                # Generate insert SQL with Arel (see https://coderwall.com/p/obrxhq/how-to-generate-activerecord-insert-sql)
                sql = new_model.class.arel_table.create_insert \
                .tap { |im| im.insert(new_model.send(
                              :arel_attributes_with_values_for_create,
                              new_model.attribute_names)) } \
                .to_sql.gsub('`', '')

                DevelopmentModelClass.connection.execute(sql)
              end
            end

            # Adjust id only when it exist
            if DevelopmentModelClass.column_names.include? 'id'
              DevelopmentModelClass.connection.execute("SELECT setval('#{table_name}_id_seq', (SELECT MAX(id) FROM #{table_name})+1); ")
            end
          end
        end

        if ProductionModelClass.column_names.include? 'typex'
          # Rename typex columns back to type
          rename_type_column(table_name, 'typex', 'type')
        end

        print "#{count} records converted\n"
      end
    end
  end
end