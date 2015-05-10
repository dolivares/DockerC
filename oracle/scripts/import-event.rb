#!/usr/bin/env ruby

# Imports individual ONEsystem events into a separate database.
#
# Set your ORACLE_SID or TWO_TASK environment variable to connect to the
# database you want to import INTO.  The script connects to this database
# with the username JADEBACKUP, password "jade".  It expects a database link
# called JADE_PROD pointed to another ONEsystem database (the source).  The
# JADE, JADE_REPORTS, ONESYSTEMCEU and REPORTING schemas should already
# exist in the target database.
#
# Call the script with one or more ONEsystem event product codes as parameters.
# The existing ONEsystem schemas will be dropped and recreated, then the data
# for the specified events will be imported across the database link.

require 'dbi'
require 'ruby-plsql'

class EventImport
  def self.import
    dp = EventImport.new
    yield dp
    dp.run
  end

  def initialize
    @dbconn = ''
    @dbusername = ''
    @dbpassword = ''
    @dblink = ''
    @schemas = Array.new
    @tablespace_mappings = Array.new
    @tables = Array.new
    @filter_params = Hash.new
    @pre_run = Array.new
    @post_run = Array.new
    @drop_schemas = false
  end

  class DatapumpJobHelper
    def initialize(*jobargs)
      @dphandle = plsql.dbms_datapump.open(*jobargs)
    end

    def method_missing(method_id, *args)
      plsql.dbms_datapump.send method_id, @dphandle, *args
    end
  end

  def connect(dbconn, username, password)
    @dbconn, @dbusername, @dbpassword = dbconn, username, password
  end

  def import_from(network_link)
    @dblink = network_link
    filter_param 'sourcedb', network_link
    filter_param 'sourcedb_current', network_link
  end

  def import_schema(schema)
    @schemas << schema
  end

  def remap_tablespace(from, to)
    @tablespace_mappings << [ from, to ]
  end

  def filter_param(param, value)
    @filter_params[param] = value
  end

  def import_table(schema, table, filter_sql = nil)
    @tables << [ schema, table, filter_sql ]
  end

  def pre_run(sql)
    @pre_run << sql
  end

  def post_run(sql)
    @post_run << sql
  end

  def drop_schemas(do_drop = true)
    @drop_schemas = do_drop
  end

  def run
    DBI.connect(@dbconn, @dbusername, @dbpassword) do |dbh|
      if (@drop_schemas)
        @schemas.each do |schema|
          puts "Dropping target schema #{schema}."
          dbh.do %{drop user "#{schema}" cascade}
        end
      end

      # Establish a consistent point-in-time for export.
      scn = dbh.select_one("select current_scn from v$database@#{@dblink}")[0]
      @scn = scn.to_i
      filter_param 'scn', @scn.to_s
      puts "Importing from SCN #{@scn} on source database."

      # Pre-run hooks.
      run_sql_hooks dbh, @pre_run

      # Give ruby-plsql the raw OCI8 handle that DBI is using.
      plsql.connection = dbh.instance_eval { @handle.instance_eval { @handle } }

      dp = DatapumpJobHelper.new 'IMPORT', 'SCHEMA', @dblink, nil, 'COMPATIBLE'

      # Set the desired schemas
      dp.metadata_filter 'SCHEMA_LIST', @schemas.collect { |s| "'#{s}'" }.join(',')

      # Exclude Java stuff.
      dp.metadata_filter 'EXCLUDE_PATH_LIST', "'JAVA_CLASS'"
      dp.metadata_filter 'EXCLUDE_PATH_LIST', "'JAVA_RESOURCE'"
      dp.metadata_filter 'EXCLUDE_PATH_LIST', "'JAVA_SOURCE'"

      # Statistics will be useless.
      dp.metadata_filter 'EXCLUDE_PATH_LIST', "'STATISTICS'"

      # Create users.
      dp.set_parameter 'USER_METADATA', 1

      # Tablespace remaps
      @tablespace_mappings.each do |mapping|
        dp.metadata_remap 'REMAP_TABLESPACE', mapping[0], mapping[1]
      end

      # We don't want data at this point.
      dp.data_filter 'INCLUDE_ROWS', 0

      puts "Importing metadata."
      dp.start_job
      job_status = dp.wait_for_job[:job_state]
      dp.detach

      if (job_status != 'COMPLETED')
        puts "Job finished with status '#{job_status}'. Aborting."
        break
      end

      # Disable foreign key constraints and triggers.
      constraints = Array.new
      triggers = Array.new

      puts "Disabling constraints and triggers."
      @tables.each do |tbl|
        schema_name, table_name, filter_sql = *tbl
        sth = dbh.execute <<-EOS, schema_name, table_name
          select constraint_name from all_constraints
           where owner = ? and table_name = ?
             and constraint_type = 'R' and status = 'ENABLED'
        EOS
        sth.each do |row|
          constraints << [ schema_name, table_name, row['CONSTRAINT_NAME'] ]
          dbh.do %{alter table "#{schema_name}"."#{table_name}" disable constraint "#{row['CONSTRAINT_NAME']}"}
        end

        sth = dbh.execute <<-EOS, schema_name, table_name
          select owner, trigger_name from all_triggers
           where table_owner = ? and table_name = ? and status = 'ENABLED'
        EOS
        sth.each do |row|
          triggers << [ row['OWNER'],  row['TRIGGER_NAME'] ]
          dbh.do %{alter trigger "#{row['OWNER']}"."#{row['TRIGGER_NAME']}" disable}
        end
      end

      # Bring over data for specified tables.
      dbh['AutoCommit'] = true
      @tables.each do |tbl|
        schema_name, table_name, filter_sql = *tbl

        import_sql = <<-EOS
          insert into "#{schema_name}"."#{table_name}"
          select * from "#{schema_name}"."#{table_name}"@#{@dblink} as of scn #{@scn} x
        EOS
        unless (filter_sql.nil?)
          # Add the filter to the query.
          import_sql << ' ' << do_param_filters(filter_sql)
        end

        print "Importing data for #{schema_name}.#{table_name}... "
        begin
          row_count = dbh.do import_sql
          printf "%d rows.\n", row_count
        rescue DBI::DatabaseError => e
          puts "FAILED!"
          puts "Error code: #{e.err}; message: #{e.errstr}"
          puts "Failing SQL is: #{import_sql}"
        end
      end

      # Post-run hooks.
      run_sql_hooks dbh, @post_run

      # Re-enable foreign key constraints and triggers.
      puts "Enabling constraints."
      constraints.each do |constraint|
        begin
          dbh.do %{alter table "#{constraint[0]}"."#{constraint[1]}" enable constraint "#{constraint[2]}"}
        rescue DBI::DatabaseError => e
          puts "Failed to enable constraint #{constraint[2]} on #{constraint[0]}.#{constraint[1]}."
          puts "Error code: #{e.err}; message: #{e.errstr}"
        end
      end

      puts "Enabling triggers."
      triggers.each do |trigger|
        dbh.do %{alter trigger "#{trigger[0]}"."#{trigger[1]}" enable}
      end

      # TODO: Generate statistics.

    end
  end

  private

  def do_param_filters(filter_sql)
    # Qualify anything from the source database with the flashback SCN.
    filter_sql = filter_sql.gsub /(@:sourcedb)\b/, "\\1 as of scn #{@scn}"
    
    # Substitute filter parameters for values.
    @filter_params.inject(filter_sql) do |memo, param|
      memo.gsub /:#{param[0]}\b/, param[1]
    end
  end

  def run_sql_hooks(dbh, sql_list)
    sql_list.each do |x|
      sql = do_param_filters(x)
      begin
        dbh.do sql
      rescue DBI::DatabaseError => e
        puts "Hook SQL failed."
        puts "Error code: #{e.err}; message: #{e.errstr}"
        puts "Failing SQL is: #{sql}"
        exit false
      end
    end
  end
end

# Convert event codes provided as arguments to event IDs.
abort "No event codes specified for import." if ARGV.empty?

event_list = Array.new
DBI.connect('dbi:OCI8:', 'jadebackup', 'jade') do |dbh|
  ARGV.each do |event_code|
    row = dbh.select_one("select to_char(eventid) from jade.event@jade_prod where eventproductcode = ?", event_code)
    abort "Invalid event code: #{event_code}." if row.nil?
    event_list << row[0]
  end
end

EventImport.import do |dp|
  dp.connect 'dbi:OCI8:', 'jadebackup', 'jade'
  dp.import_from 'JADE_PROD'
  dp.import_schema 'JADE'
  dp.import_schema 'JADE_REPORTS'
  dp.import_schema 'REPORTING'
  dp.import_schema 'ONESYSTEMCEU'

  dp.remap_tablespace 'WJ_DATA', 'USERS'
  dp.remap_tablespace 'WJ_INDEX', 'USERS'
  dp.remap_tablespace 'WJ_XLOG', 'USERS'
  dp.remap_tablespace 'WJ_XLOG_INDEX', 'USERS'
  dp.remap_tablespace 'WJ_LOB', 'USERS'
  dp.remap_tablespace 'WJ_CEU_DATA', 'USERS'
  dp.remap_tablespace 'WJ_CEU_INDEX', 'USERS'
  dp.remap_tablespace 'WJ_REPORT_DATA', 'USERS'
  dp.remap_tablespace 'WJ_REPORT_INDEX', 'USERS'

  dp.filter_param 'eventid', event_list.join(',')

  dp.drop_schemas

  # Populate temp table with list of people we want to grab...
  # Err... export.
  dp.pre_run <<-EOS
    insert into jade.person_temp_list@:sourcedb_current (personid)
    select r.personid from jade.registrant@:sourcedb r
     where exists (select * from jade.regcategory_type@:sourcedb rct
         where rct.regcattypeid = r.regcattypeid and exists
           (select * from jade.regtype@:sourcedb rt
             where rt.regtypeid = rct.regtypeid
               and rt.eventid in (:eventid)))
    union select rm.personid from jade.reservationmaster@:sourcedb rm
           where exists (select * from jade.block@:sourcedb b
               where b.blockid = rm.blockid
                 and b.eventid in (:eventid))
    union select rg.personid from jade.reservationguest@:sourcedb rg
           where exists (select * from jade.reservationmaster@:sourcedb rm
               where rm.reservationmasterid = rg.reservationmasterid and exists
                 (select * from jade.block@:sourcedb b
                   where b.blockid = rm.blockid
                     and b.eventid in (:eventid)))
    union select eh.contactid from jade.eventhotel@:sourcedb eh
           where eh.eventid in (:eventid)
             and eh.contactid is not null
    union select a.personid from jade.allocation@:sourcedb a
           where exists (select * from jade.block@:sourcedb b
               where b.blockid = a.blockid
                 and b.eventid in (:eventid))
    union select ui.personid from jade.userinfo@:sourcedb ui
           where ui.personid is not null
  EOS

  # Lookup tables. Get all rows.
  dp.import_table 'JADE', 'AARP_PLUGINCONFIG'
  dp.import_table 'JADE', 'ADDRESSTYPE'
  dp.import_table 'JADE', 'ADDRESS_COUNTRIES'
  dp.import_table 'JADE', 'ADDRESS_STATES'
  dp.import_table 'JADE', 'AORN_PLUGINCONFIG'
  dp.import_table 'JADE', 'API_USERS'
  dp.import_table 'JADE', 'API_USER_PERMISSIONS'
  dp.import_table 'JADE', 'BADGEMEDIATYPE'
  dp.import_table 'JADE', 'BADGEPRINTER'
  dp.import_table 'JADE', 'BADGEPRINTER_USER'
  dp.import_table 'JADE', 'BADGEPRINTERTYPE'
  dp.import_table 'JADE', 'COUNTRY_ALIAS'
  dp.import_table 'JADE', 'COUNTRY_CODE'
  dp.import_table 'JADE', 'CUSTOMFIELDTYPE'
  dp.import_table 'JADE', 'EMC_PAYMENTTYPE_CLASS'
  dp.import_table 'JADE', 'FUNCTIONFLAG'
  dp.import_table 'JADE', 'GROUPHOUSING_DEFAULT_TEXT'
  dp.import_table 'JADE', 'HIST_COLUMNS'
  dp.import_table 'JADE', 'HUI_EXTENDED_PARAMTYPES'
  dp.import_table 'JADE', 'HUI_FIELDCONSTANTS'
  dp.import_table 'JADE', 'HUI_LOCALES'
  dp.import_table 'JADE', 'HUI_WEBHOOK_PARAM_FIELDS'
  dp.import_table 'JADE', 'ITEMTYPE'
  dp.import_table 'JADE', 'OSSR_EMC_DYTEXT_PAGENAME'
  dp.import_table 'JADE', 'PAYDETFLAGS'
  dp.import_table 'JADE', 'PAYMENTCURRENCY'
  dp.import_table 'JADE', 'PAYMENTTYPE'
  dp.import_table 'JADE', 'PAYMENTTYPEDETAILS'
  dp.import_table 'JADE', 'PAYTYPEDET_DETFLAGS'
  dp.import_table 'JADE', 'PHONETYPE'
  dp.import_table 'JADE', 'PROFILEFIELD'
  dp.import_table 'JADE', 'ROOMTYPE'
  dp.import_table 'JADE', 'UDFTYPE'
  dp.import_table 'JADE', 'USERFUNCTION'
  dp.import_table 'JADE', 'USERINFO'
  dp.import_table 'JADE', 'USERINFO_USERROLE'
  dp.import_table 'JADE', 'USERROLE'
  dp.import_table 'JADE', 'USERROLE_FUNCTION'
  dp.import_table 'JADE', 'USERROLE_FUNCTIONFLAG'
  dp.import_table 'JADE', 'WEBSERVICES'
  dp.import_table 'JADE', 'ZIPCODES'

  dp.import_table 'JADE_REPORTS', 'REPORTS'
  dp.import_table 'JADE_REPORTS', 'REPORTS_NAVLINKS'
  dp.import_table 'JADE_REPORTS', 'REPORTS_USER'
  dp.import_table 'JADE_REPORTS', 'REPORTS_USER_NAVLINKS'
  dp.import_table 'JADE_REPORTS', 'REPORTS_USER_REPORTS'
  dp.import_table 'JADE_REPORTS', 'REPORTS_PROFILES'

  CLIENT_FILTER = <<-EOS
    where exists (select * from jade.event@:sourcedb e
                   where e.clientid = x.clientid
                     and e.eventid in (:eventid))
  EOS

  EVENT_FILTER = <<-EOS
    where eventid in (:eventid)
  EOS

  REGTYPE_FILTER = <<-EOS
    where exists (select * from jade.regtype@:sourcedb rt
                   where rt.regtypeid = x.regtypeid
                     and rt.eventid in (:eventid))
  EOS

  INVENTORY_FILTER = <<-EOS
    where exists (select * from jade.regtype@:sourcedb rt
                   where rt.regtypeid = x.inventoryid
                     and rt.eventid in (:eventid))
       or exists (select * from jade.eventinventory@:sourcedb ei
                   where ei.inventoryid = x.inventoryid
                     and ei.eventid in (:eventid))
       or exists (select * from jade.coursesession@:sourcedb cs
                   where cs.sessionid = x.inventoryid and exists
                     (select * from jade.course@:sourcedb c
                       where cs.courseid = c.courseid
                         and c.eventid in (:eventid)))
       or exists (select * from jade.invoiceitem@:sourcedb ii
                   where ii.itemid = x.inventoryid and exists
                     (select * from jade.registrant@:sourcedb r
                       where r.registrantid = ii.registrantid and exists
                         (select * from jade.regcategory_type@:sourcedb rct
                           where rct.regcattypeid = r.regcattypeid and exists
                             (select * from jade.regtype@:sourcedb rt
                               where rt.regtypeid = rct.regtypeid
                                 and rt.eventid in (:eventid)))))
  EOS

  PERSON_FILTER = <<-EOS
    where exists (select * from jade.person_temp_list@:sourcedb_current p
                   where p.personid = x.personid)
  EOS

  REGISTRANT_FILTER = <<-EOS
    where exists (select * from jade.registrant@:sourcedb r
                   where r.registrantid = x.registrantid and exists
                     (select * from jade.regcategory_type@:sourcedb rct
                       where rct.regcattypeid = r.regcattypeid and exists
                         (select * from jade.regtype@:sourcedb rt
                           where rt.regtypeid = rct.regtypeid
                             and rt.eventid in (:eventid))))
  EOS

  BLOCK_FILTER = <<-EOS
    where exists (select * from jade.block@:sourcedb b
                   where b.blockid = x.blockid
                     and b.eventid in (:eventid))
  EOS

  SESSION_FILTER = <<-EOS
    where exists (select * from jade.coursesession@:sourcedb cs
                   where cs.sessionid = x.sessionid and exists
                     (select * from jade.course@:sourcedb c
                       where cs.courseid = c.courseid
                         and c.eventid in (:eventid)))
  EOS

  VENUESEATINGARRANGEMENT_FILTER = <<-EOS
    where exists (select * from jade.coursesession@:sourcedb cs
                   where cs.venueseatingarrangementid = x.venueseatingarrangementid and exists
                     (select * from jade.course@:sourcedb c
                       where cs.courseid = c.courseid
                         and c.eventid in (:eventid)))
  EOS

  RESERVATIONMASTER_FILTER = <<-EOS
    where exists (select * from jade.reservationmaster@:sourcedb rm
                   where rm.reservationmasterid = x.reservationmasterid and exists
                     (select * from jade.block@:sourcedb b
                       where b.blockid = rm.blockid
                         and b.eventid in (:eventid)))
  EOS

  HOTEL_FILTER = <<-EOS
    where exists (select * from jade.eventhotel@:sourcedb eh
                   where eh.hotelid = x.hotelid
                     and eh.eventid in (:eventid))
  EOS

  TENDERTRANSACTION_FILTER = <<-EOS
    where x.tendertransactid in (select ti.tendertransactid from jade.tenderitem@:sourcedb ti
                                  where exists (select * from jade.registrant@:sourcedb r
                                                 where r.registrantid = ti.registrantid and exists
                                                   (select * from jade.regcategory_type@:sourcedb rct
                                                     where rct.regcattypeid = r.regcattypeid and exists
                                                       (select * from jade.regtype@:sourcedb rt
                                                         where rt.regtypeid = rct.regtypeid
                                                           and rt.eventid in (:eventid))))
                                 union select rt.tendertransactid from jade.reservationtransaction@:sourcedb rt
                                  where exists (select * from jade.reservationmaster@:sourcedb rm
                                                 where rm.reservationmasterid = rt.reservationmasterid and exists
                                                   (select * from jade.block@:sourcedb b
                                                     where b.blockid = rm.blockid
                                                       and b.eventid in (:eventid))))
  EOS

  SEAT_FILTER = <<-EOS
    where exists (select * from jade.venueseatingarrgmt_seat@:sourcedb vsas
                   where vsas.seatid = x.seatid and exists
                     (select * from jade.coursesession@:sourcedb cs
                       where vsas.venueseatingarrangementid = cs.venueseatingarrangementid and exists
                         (select * from jade.course@:sourcedb c
                           where cs.courseid = c.courseid
                             and c.eventid in (:eventid))))
  EOS

  EMC_FILTER = <<-EOS
    where exists (select * from jade.ossr_emc_setup@:sourcedb o
                   where o.ossr_emc_id = x.ossr_emc_id
                     and o.eventid in (:eventid))
  EOS

  EXHIBITOR_FILTER = <<-EOS
    where exists (select * from jade.emc_exhibitor@:sourcedb e
                   where e.exhibitorid = x.exhibitorid
                     and e.eventid in (:eventid))
  EOS

  CONFIRMATION_FILTER = <<-EOS
    where exists (select * from jade.eventconfirmation@:sourcedb ec
                   where ec.confirmationid = x.confirmationid
                     and ec.eventid in (:eventid))
  EOS

  EVENTPRODUCTCODE_FILTER = <<-EOS
    where exists (select * from jade.event@:sourcedb e
                   where e.eventproductcode = x.eventproductcode
                     and e.eventid in (:eventid))
  EOS

  ADDRESS_FILTER = <<-EOS
    where x.addressid in (select v.addressid from jade.venue@:sourcedb v
                           where exists (select * from jade.event@:sourcedb e
                                          where e.venueid = v.venueid
                                            and e.eventid in (:eventid))
                              or exists (select * from jade.venueseatingarrangement@:sourcedb vsa
                                          where vsa.venueid = v.venueid and exists
                                            (select * from jade.coursesession@:sourcedb cs
                                              where cs.venueseatingarrangementid = vsa.venueseatingarrangementid and exists
                                                (select * from jade.course@:sourcedb c
                                                  where c.courseid = cs.courseid
                                                    and c.eventid in (:eventid))))
                          union select pa.addressid from jade.personaddress@:sourcedb pa
                           where exists (select * from jade.person_temp_list@:sourcedb_current ptl
                                          where pa.personid = ptl.personid)
                          union select o.addressid from jade.organization@:sourcedb o
                           where o.organizationid in (select eh.hotelid from jade.eventhotel@:sourcedb eh
                                                       where eh.eventid in (:eventid)
                                                      union select a.organizationid from jade.allocation@:sourcedb a
                                                       where exists (select * from jade.block@:sourcedb b
                                                                      where a.blockid = b.blockid
                                                                        and b.eventid in (:eventid))
                                                      union select p.organizationid from jade.preapproval@:sourcedb p
                                                       where p.eventid in (:eventid)
                                                      union select rc.organizationid from jade.regcap@:sourcedb rc
                                                       where exists (select * from jade.regtype@:sourcedb rt
                                                                      where rc.regtypeid = rt.regtypeid
                                                                        and rt.eventid in (:eventid))
                                                      union select p.organizationid from jade.person@:sourcedb p
                                                       where exists (select * from jade.person_temp_list@:sourcedb_current ptl
                                                                      where p.personid = ptl.personid)))
  EOS


# End filter defs

  dp.import_table 'JADE', 'CLIENT', CLIENT_FILTER

  dp.import_table 'JADE', 'CLIENT_EVENTACRONYM', CLIENT_FILTER

  dp.import_table 'JADE', 'CLIENT_MEMBERS', CLIENT_FILTER

  dp.import_table 'JADE', 'WEBSERVICES_CLIENT', CLIENT_FILTER

  dp.import_table 'JADE', 'WEBSERVICES_CLIENT_IPRESTRICT', CLIENT_FILTER

  dp.import_table 'JADE', 'WEBSERVICES_CLIENT_SERVICES', CLIENT_FILTER

  dp.import_table 'JADE', 'VENUE', <<-EOS
    where exists (select * from jade.event@:sourcedb e
                   where e.venueid = x.venueid
                     and e.eventid in (:eventid))
       or exists (select * from jade.venueseatingarrangement@:sourcedb vsa
                   where vsa.venueid = x.venueid and exists
                     (select * from jade.coursesession@:sourcedb cs
                       where cs.venueseatingarrangementid = vsa.venueseatingarrangementid and exists
                         (select * from jade.course@:sourcedb c
                           where cs.courseid = c.courseid
                             and c.eventid in (:eventid))))
  EOS

  dp.import_table 'JADE', 'EVENT', EVENT_FILTER

  dp.import_table 'JADE', 'PAYMENTACCEPTANCE', EVENT_FILTER

  dp.import_table 'JADE', 'PAYMENTACCEPTANCE_PAYMENTTYPE', EVENT_FILTER

  dp.import_table 'JADE', 'EVENTACRONYM', <<-EOS
    where exists (select * from jade.client_eventacronym@:sourcedb cea
                   where cea.eventacronymid = x.eventacronymid and exists
                     (select * from jade.event@:sourcedb e
                       where cea.clientid = e.clientid
                         and e.eventid in (:eventid)))
  EOS

  dp.import_table 'JADE', 'EVENTPAYFLOWPRO', EVENT_FILTER

  dp.import_table 'JADE', 'EVENTPLUGIN', EVENT_FILTER

  dp.import_table 'JADE', 'EVENTPROFILEFIELD', EVENT_FILTER

  dp.import_table 'JADE', 'PROMO_CODE', EVENT_FILTER

  dp.import_table 'JADE', 'COUPON', EVENT_FILTER

  dp.import_table 'JADE', 'AMENITYORDER', EVENT_FILTER

  dp.import_table 'JADE', 'EVENTHOTEL', EVENT_FILTER

  dp.import_table 'JADE', 'HOTEL', HOTEL_FILTER

  dp.import_table 'JADE', 'HOTELROOMTYPE', HOTEL_FILTER

  dp.import_table 'JADE', 'HOTEL_I18N', HOTEL_FILTER

  dp.import_table 'JADE', 'HOTELTRANSFER', EVENT_FILTER

  dp.import_table 'JADE', 'HOTEL_IMAGE', HOTEL_FILTER

  dp.import_table 'JADE', 'BLOCKROOMTYPE', BLOCK_FILTER

  dp.import_table 'JADE', 'BLOCKCONTACTTYPE', BLOCK_FILTER

  dp.import_table 'JADE', 'BLOCK', EVENT_FILTER

  dp.import_table 'JADE', 'BLOCK_I18N', BLOCK_FILTER

  dp.import_table 'JADE', 'MASTERBLOCKDATE', BLOCK_FILTER

  dp.import_table 'JADE', 'SALEABLEBLOCKDATE_BASE', BLOCK_FILTER

  dp.import_table 'JADE', 'ALLOCATION', BLOCK_FILTER

  dp.import_table 'JADE', 'ALLOCATIONDATE_BASE', <<-EOS
    where exists (select * from jade.allocation@:sourcedb a
                   where a.allocationid = x.allocationid and exists
                     (select * from jade.block@:sourcedb b
                       where a.blockid = b.blockid
                         and b.eventid in (:eventid)))
  EOS

  dp.import_table 'JADE', 'ALLOCATIONDATEEFFDATE', <<-EOS
    where exists (select * from jade.allocation@:sourcedb a
                   where a.allocationid = x.allocationid and exists
                     (select * from jade.block@:sourcedb b
                       where a.blockid = b.blockid
                         and b.eventid in (:eventid)))
  EOS

  dp.import_table 'JADE', 'PACED_MASTERBLOCKDATE', EVENT_FILTER

  dp.import_table 'JADE', 'PACED_RESERVATIONDATE', EVENT_FILTER

  dp.import_table 'JADE', 'PACED_SALEABLEBLOCKDATE', EVENT_FILTER

  dp.import_table 'JADE', 'CONTACTTYPE', EVENT_FILTER

  dp.import_table 'JADE', 'BADGELAYOUT', EVENT_FILTER

  dp.import_table 'JADE', 'BADGELAYOUT_INVENTORY', <<-EOS
    where exists (select * from jade.badgelayout@:sourcedb bl
                   where bl.badgelayoutid = x.badgelayoutid
                     and bl.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'BADGELAYOUT_SELECTOR', <<-EOS
    where exists (select * from jade.badgelayout@:sourcedb bl
                   where bl.badgelayoutid = x.badgelayoutid
                     and bl.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'EVENTINVENTORY', EVENT_FILTER

  dp.import_table 'JADE', 'COURSE', EVENT_FILTER

  dp.import_table 'JADE', 'COURSE_I18N', <<-EOS
    where exists (select * from jade.course@:sourcedb c
                   where c.courseid = x.courseid
                     and c.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'COURSESESSION', <<-EOS
    where exists (select * from jade.course@:sourcedb c
                   where c.courseid = x.courseid
                     and c.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'COURSESESSION_I18N', SESSION_FILTER

  dp.import_table 'JADE', 'SESSIONTIME', SESSION_FILTER

  dp.import_table 'JADE', 'COURSESESSION_OBJECTIVE', SESSION_FILTER

  dp.import_table 'JADE', 'COURSESESS_VENSEATSEAT', SESSION_FILTER

  dp.import_table 'JADE', 'INVENTORY_BASE', INVENTORY_FILTER

  dp.import_table 'JADE', 'INVENTORY_I18N', INVENTORY_FILTER

  dp.import_table 'JADE', 'INVOICEITEM', REGISTRANT_FILTER

  dp.import_table 'JADE', 'REGISTRANT_SESSION', REGISTRANT_FILTER

  dp.import_table 'JADE', 'SURVEY', EVENT_FILTER

  dp.import_table 'JADE', 'SURVEY_I18N', <<-EOS
    where exists (select * from jade.survey@:sourcedb s
                   where s.surveyid = x.surveyid
                     and s.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'SURVEYQUESTION', EVENT_FILTER

  dp.import_table 'JADE', 'SURVEYQUESTION_I18N', <<-EOS
    where exists (select * from jade.surveyquestion@:sourcedb sq
                   where sq.surveyquestionid = x.surveyquestionid
                     and sq.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'SURVEYANSWERSET', <<-EOS
    where exists (select * from jade.surveyquestion@:sourcedb sq
                   where sq.answersetid = x.answersetid
                     and sq.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'SURVEYANSWERSET_SURVEYANSWER', <<-EOS
    where exists (select * from jade.surveyquestion@:sourcedb sq
                   where sq.answersetid = x.answersetid
                     and sq.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'SURVEYANSWER', <<-EOS
    where exists (select * from jade.surveyanswerset_surveyanswer@:sourcedb sasa
                   where sasa.surveyanswerid = x.surveyanswerid and exists
                     (select * from jade.surveyquestion@:sourcedb sq
                       where sq.answersetid = sasa.answersetid
                         and sq.eventid in (:eventid)))
  EOS

  dp.import_table 'JADE', 'SURVEYANSWER_I18N', <<-EOS
    where exists (select * from jade.surveyanswerset_surveyanswer@:sourcedb sasa
                   where sasa.surveyanswerid = x.surveyanswerid and exists
                     (select * from jade.surveyquestion@:sourcedb sq
                       where sq.answersetid = sasa.answersetid
                         and sq.eventid in (:eventid)))
  EOS

  dp.import_table 'JADE', 'REGTYPE_SURVEY', REGTYPE_FILTER

  dp.import_table 'JADE', 'REGTYPE', EVENT_FILTER

  dp.import_table 'JADE', 'REGCATEGORY', EVENT_FILTER

  dp.import_table 'JADE', 'REGCATEGORY_I18N', <<-EOS
    where exists (select * from jade.regcategory@:sourcedb rc
                   where rc.regcategoryid = x.regcategoryid
                     and rc.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'REGCATEGORY_TYPE', REGTYPE_FILTER

  dp.import_table 'JADE', 'REGPRICE', REGTYPE_FILTER

  dp.import_table 'JADE', 'REGTYPEINVENTORY', REGTYPE_FILTER

  dp.import_table 'JADE', 'REGINVENTORYPRICE', REGTYPE_FILTER

  dp.import_table 'JADE', 'REGCAP', REGTYPE_FILTER

  dp.import_table 'JADE', 'CONFIRMATION', CONFIRMATION_FILTER

  dp.import_table 'JADE', 'EVENTCONFIRMATION', EVENT_FILTER

  dp.import_table 'JADE', 'CONFIRMATIONFIELD', CONFIRMATION_FILTER

  dp.import_table 'JADE', 'EVENTCONFIRMVALUE', EVENT_FILTER

  dp.import_table 'JADE', 'LOGO', <<-EOS
    where exists (select * from jade.confirmationlogo@:sourcedb cl
                   where cl.logoname = x.logoname and exists
                     (select * from jade.eventconfirmation@:sourcedb ec
                       where cl.confirmationid = ec.confirmationid
                         and ec.eventid in (:eventid)))
  EOS

  dp.import_table 'JADE', 'CONFIRMATIONLOGO', CONFIRMATION_FILTER

  dp.import_table 'JADE', 'USERDEFINEDFIELD', EVENT_FILTER

  dp.import_table 'JADE', 'USERDEFINEDFIELD_I18N', <<-EOS
    where exists (select * from jade.userdefinedfield@:sourcedb udf
                   where udf.userdefinedfieldid = x.userdefinedfieldid
                     and udf.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'CUSTOMFIELD', EVENT_FILTER

  dp.import_table 'JADE', 'CUSTOMFIELDGROUP', EVENT_FILTER

  dp.import_table 'JADE', 'CUSTOMFIELDGROUP_REGTYPE', <<-EOS
    where exists (select * from jade.customfieldgroup@:sourcedb cfg
                   where cfg.customfieldgroupid = x.customfieldgroupid
                     and cfg.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'CUSTOMFIELDVALUE_BLOB', <<-EOS
    where exists (select * from jade.customfield@:sourcedb cf
                   where cf.customfieldid = x.customfieldid
                     and cf.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'CONFIRMATION2', EVENT_FILTER

  dp.import_table 'JADE', 'CONFIRMATION2_LOCALIZED', <<-EOS
    where exists (select * from jade.confirmation2@:sourcedb c
                   where c.confirmationid = x.confirmationid
                     and c.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'PERSON', PERSON_FILTER

  dp.import_table 'JADE', 'PERSONADDRESS', PERSON_FILTER

  dp.import_table 'JADE', 'PERSONPHONE', PERSON_FILTER

  dp.import_table 'JADE', 'PERSONUDFVALUE', PERSON_FILTER

  dp.import_table 'JADE', 'PERSON_NOTE', PERSON_FILTER

  dp.import_table 'JADE', 'PERSON_SURVEYANSWER', EVENT_FILTER

  dp.import_table 'JADE', 'PERSON_SURVEYANSWER_MULTI', EVENT_FILTER

  dp.import_table 'JADE', 'REGISTRANT', <<-EOS
    where exists (select * from jade.regcategory_type@:sourcedb rct
                   where rct.regcattypeid = x.regcattypeid and exists
                     (select * from jade.regtype@:sourcedb rt
                       where rt.regtypeid = rct.regtypeid
                         and rt.eventid in (:eventid)))
  EOS

  dp.import_table 'JADE', 'RESERVATIONMASTER', BLOCK_FILTER

  dp.import_table 'JADE', 'RESERVATIONDATE', RESERVATIONMASTER_FILTER

  dp.import_table 'JADE', 'RESERVATIONGUEST', RESERVATIONMASTER_FILTER

  dp.import_table 'JADE', 'RESERVATIONTRANSACTION', RESERVATIONMASTER_FILTER

  dp.import_table 'JADE', 'TENDERTRANSACTION', TENDERTRANSACTION_FILTER

  dp.import_table 'JADE', 'TENDERDETAIL', TENDERTRANSACTION_FILTER

  dp.import_table 'JADE', 'TENDERITEM', REGISTRANT_FILTER

  dp.import_table 'JADE', 'AARP_EVENTCONFIG', EVENT_FILTER

  dp.import_table 'JADE', 'AARP_JOINRENEW_CONFIG', INVENTORY_FILTER

  dp.import_table 'JADE', 'AARP_REGTYPECONFIG', REGTYPE_FILTER

  dp.import_table 'JADE', 'AARP_WS_UPDATE_LOG', EVENT_FILTER

  dp.import_table 'JADE', 'AORN_EVENTCONFIG', EVENT_FILTER

  dp.import_table 'JADE', 'AORN_REGTYPECONFIG', REGTYPE_FILTER

  dp.import_table 'JADE', 'AORN_WS_SESSION_UPDATE_LOG', SESSION_FILTER

  dp.import_table 'JADE', 'AORN_WS_UPDATE_LOG', REGISTRANT_FILTER

  dp.import_table 'JADE', 'HUI_AMENITY_LABELS', EVENT_FILTER

  dp.import_table 'JADE', 'HUI_EVENTPAYMENTTYPE', EVENT_FILTER

  dp.import_table 'JADE', 'HUI_EVENTSETUP', EVENT_FILTER

  dp.import_table 'JADE', 'HUI_EXTENDED_PARAMS', EVENT_FILTER

  dp.import_table 'JADE', 'HUI_FIELD_LABELS', EVENT_FILTER

  dp.import_table 'JADE', 'HUI_MOBILESETUP', EVENT_FILTER

  dp.import_table 'JADE', 'HUI_REDIRECT_BUTTON_LABELS', <<-EOS
    where buttonid in (select buttonid from jade.hui_redirect_buttons@:sourcedb
                        where eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'HUI_REDIRECT_BUTTONS', EVENT_FILTER

  dp.import_table 'JADE', 'HUI_ROOMTYPE_LABELS', EVENT_FILTER

  dp.import_table 'JADE', 'HUI_WEBHOOK_PARAMS', EVENT_FILTER

  dp.import_table 'JADE', 'HUI_WEBHOOKS', EVENT_FILTER

  dp.import_table 'JADE', 'EXHIBITOR_WELCOME_LETTER', EVENT_FILTER

  dp.import_table 'JADE', 'VENUESEATINGARRANGEMENT', VENUESEATINGARRANGEMENT_FILTER

  dp.import_table 'JADE', 'VENUESEATINGARRGMT_SEAT', VENUESEATINGARRANGEMENT_FILTER

  dp.import_table 'JADE', 'VENSEATINGGRP_GRPLABEL', VENUESEATINGARRANGEMENT_FILTER

  dp.import_table 'JADE', 'SEATINGGROUP', VENUESEATINGARRANGEMENT_FILTER

  dp.import_table 'JADE', 'SEATINGGROUP_SEAT', SEAT_FILTER

  dp.import_table 'JADE', 'REGTYPEINVENTORY_SEATGRP', REGTYPE_FILTER

  dp.import_table 'JADE', 'SEAT', SEAT_FILTER

  dp.import_table 'JADE', 'SEATINGGROUPLABEL', <<-EOS
    where exists (select * from jade.venseatinggrp_grplabel@:sourcedb vsggl
                   where vsggl.seatinggrouplabelid = x.seatinggrouplabelid and exists
                     (select * from jade.coursesession@:sourcedb cs
                       where cs.venueseatingarrangementid = vsggl.venueseatingarrangementid and exists
                         (select * from jade.course@:sourcedb c
                           where cs.courseid = c.courseid
                             and c.eventid in (:eventid))))
  EOS

  dp.import_table 'JADE', 'SEATINGGROUPLABEL_SEAT', SEAT_FILTER

  dp.import_table 'JADE', 'NOTE', <<-EOS
    where x.noteid in (select noteid
                         from (select personid, noteid from jade.person_note@:sourcedb
                               union select personid, noteid from jade.personaddress@:sourcedb
                               union select personid, noteid from jade.personphone@:sourcedb
                               union select personid, noteid from jade.reservationmaster@:sourcedb
                               union select personid, commentnoteid from jade.reservationmaster@:sourcedb) n
                        where exists (select * from jade.person_temp_list@:sourcedb_current ptl
                                       where n.personid = ptl.personid)
                          and n.noteid is not null)
  EOS

  dp.import_table 'JADE', 'EMC_BOOTH', EVENT_FILTER

  dp.import_table 'JADE', 'EMC_BOOTHITEMS', EVENT_FILTER

  dp.import_table 'JADE', 'EMC_BOOTH_SHARING', <<-EOS
    where exists (select * from jade.emc_booth@:sourcedb b
                   where b.boothid = x.boothid
                     and b.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'EMC_BULK', EVENT_FILTER

  dp.import_table 'JADE', 'EMC_CONFIRMATION_TEMPLATE', EMC_FILTER

  dp.import_table 'JADE', 'EMC_DIRECTORYCATEGORY', EVENT_FILTER

  dp.import_table 'JADE', 'EMC_DIRECTORYIMAGE', EVENT_FILTER

  dp.import_table 'JADE', 'EMC_DIRECTORYTEXTLIMIT', EVENT_FILTER

  dp.import_table 'JADE', 'EMC_DIRECTORYUPGRADE$', EVENT_FILTER

  dp.import_table 'JADE', 'EMC_EVENTCONFIG', EVENT_FILTER

  dp.import_table 'JADE', 'EMC_EXHIBITOR', EVENT_FILTER

  dp.import_table 'JADE', 'EMC_EXHIBITOR_CATEGORY_ALLOT', EXHIBITOR_FILTER

  dp.import_table 'JADE', 'EMC_EXHIBITOR_DIRECTORYCAT', EXHIBITOR_FILTER

  dp.import_table 'JADE', 'EMC_EXTRAALLOTMENT', EVENT_FILTER

  dp.import_table 'JADE', 'EMC_INT_REGTYPE', EVENT_FILTER

  dp.import_table 'JADE', 'EMC_INVENTORY$', EVENT_FILTER

  dp.import_table 'JADE', 'EMC_INVOICEITEM', REGISTRANT_FILTER

  dp.import_table 'JADE', 'EMC_MODULE', EMC_FILTER

  dp.import_table 'JADE', 'EMC_PAGE', <<-EOS
    where exists (select * from jade.ossr_emc_setup@:sourcedb o
                   where o.emc_pagesetid = x.pagesetid
                     and o.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'EMC_PAGESET', <<-EOS
    where exists (select * from jade.ossr_emc_setup@:sourcedb o
                   where o.emc_pagesetid = x.pagesetid
                     and o.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'EMC_PAGE_REQUIREMENTS', <<-EOS
    where exists (select * from jade.emc_page@:sourcedb p
                   where p.pageid = x.pageid and exists
                     (select * from jade.ossr_emc_setup@:sourcedb o
                       where p.pagesetid = o.emc_pagesetid
                         and o.eventid in (:eventid)))
  EOS

  dp.import_table 'JADE', 'EMC_PAGE_REQUIREMENT_OBJECTS', <<-EOS
    where exists (select * from jade.emc_page_requirements@:sourcedb r
                   where r.objectid = x.objectid and exists
                     (select * from jade.emc_page@:sourcedb p
                       where p.pageid = r.pageid and exists
                         (select * from jade.ossr_emc_setup@:sourcedb o
                           where p.pagesetid = o.emc_pagesetid
                             and o.eventid in (:eventid))))
  EOS

  dp.import_table 'JADE', 'EMC_PAGE_XSL', <<-EOS
    where exists (select * from jade.ossr_emc_setup@:sourcedb o
                   where o.ossr_emc_id = x.ossr_emc_id
                     and o.eventid in (:eventid))
      and exists (select * from jade.emc_page@:sourcedb p
                   where p.pageid = x.pageid and exists
                     (select * from jade.ossr_emc_setup@:sourcedb o
                       where o.emc_pagesetid = p.pagesetid
                         and o.eventid in (:eventid)))
  EOS

  dp.import_table 'JADE', 'EMC_PAGE_XSL_REQUIREMENTS', <<-EOS
    where exists (select * from jade.ossr_emc_setup@:sourcedb o
                   where o.ossr_emc_id = x.ossr_emc_id
                     and o.eventid in (:eventid))
      and exists (select * from jade.emc_page@:sourcedb p
                   where p.pageid = x.pageid and exists
                     (select * from jade.ossr_emc_setup@:sourcedb o
                       where o.emc_pagesetid = p.pagesetid
                         and o.eventid in (:eventid)))
  EOS

  dp.import_table 'JADE', 'EMC_PAYMENTACCEPTANCE', EVENT_FILTER

  dp.import_table 'JADE', 'EMC_PREAPPROVAL', EVENT_FILTER

  dp.import_table 'JADE', 'EMC_PREAPPROVAL_LETTER', EVENT_FILTER

  dp.import_table 'JADE', 'EMC_REGISTRABLE_CATEGORY', EMC_FILTER

  dp.import_table 'JADE', 'EMC_RELATIONSHIP', EVENT_FILTER

  dp.import_table 'JADE', 'OSSR_ADMIN_REPORTS', <<-EOS
    where exists (select * from jade.ossr_admin_setup@:sourcedb o
                   where o.ossr_admin_id = x.ossr_admin_id
                     and o.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'OSSR_EMC_DYTEXT', EMC_FILTER

  dp.import_table 'JADE', 'OSSR_EMC_EXTRAALLOTMENT', EVENT_FILTER

  dp.import_table 'JADE', 'OSSR_REPORTS', <<-EOS
    where exists (select * from jade.ossr_admin_setup@:sourcedb o
                   where o.ossr_admin_id = x.ossr_admin_id
                     and o.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'OSSR_REQUIREDFIELDS', EVENT_FILTER

  dp.import_table 'JADE', 'OSSR_ADMIN_SETUP', EVENT_FILTER

  dp.import_table 'JADE', 'OSSR_EMC_SETUP', EVENT_FILTER

  dp.import_table 'JADE', 'VIRTBADGE_ATTENDEE_EDIT_LOG', REGISTRANT_FILTER

  dp.import_table 'JADE', 'VIRTBADGE_BADGE', EVENT_FILTER

  dp.import_table 'JADE', 'VIRTBADGE_FIELDS', <<-EOS
    where exists (select * from jade.virtbadge_badge@:sourcedb b
                   where b.badge_id = x.badge_id
                     and b.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'VIRTBADGE_STATIC', <<-EOS
    where exists (select * from jade.virtbadge_fields@:sourcedb f
                   where f.field_id = x.field_id and exists
                     (select * from jade.virtbadge_badge@:sourcedb b
                       where f.badge_id = b.badge_id
                         and b.eventid in (:eventid)))
  EOS

  dp.import_table 'JADE', 'REPORTS_LOGIN', <<-EOS
    where eventid in (:eventid)
       or eventid is null
  EOS

  dp.import_table 'JADE', 'PREAPPROVAL', EVENT_FILTER

  dp.import_table 'JADE', 'VIRAL_MARKETING_EMAIL_SETUP', EVENT_FILTER

  dp.import_table 'JADE', 'WELCOME_LETTERS', EVENT_FILTER

  dp.import_table 'JADE', 'INTRANET', EVENT_FILTER

  dp.import_table 'JADE', 'INTRANET_CONTACT', <<-EOS
    where exists (select * from jade.intranet@:sourcedb i
                   where i.intranetid = x.intranetid
                     and i.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'MEMBERORGVALIDATION', EVENTPRODUCTCODE_FILTER

  dp.import_table 'JADE', 'MEMBERVALIDATION_BASE', EVENTPRODUCTCODE_FILTER

  dp.import_table 'JADE', 'PAYMENT_PO', EVENT_FILTER

  dp.import_table 'JADE', 'PAYMENT_PO_INVOICE', <<-EOS
    where exists (select * from jade.payment_po@:sourcedb p
                   where p.poid = x.poid
                     and p.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'PAYMENT_PO_INVOICE_TEMPLATE', <<-EOS
    where exists (select * from jade.payment_po_inv_temp_event@:sourcedb t
                   where t.templateid = x.templateid
                     and t.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'PAYMENT_PO_INV_TEMP_EVENT', EVENT_FILTER

  dp.import_table 'JADE', 'PAYMENT_PO_PERSON', <<-EOS
    where exists (select * from jade.payment_po@:sourcedb p
                   where p.poid = x.poid
                     and p.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'PAYMENT_PO_TRANSACTION', <<-EOS
    where exists (select * from jade.payment_po@:sourcedb p
                   where p.poid = x.poid
                     and p.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'PAYMENT_PO_TRANS_PERSON', <<-EOS
    where exists (select * from jade.payment_po_transaction@:sourcedb t
                   where t.potid = x.potid and exists
                     (select * from jade.payment_po@:sourcedb p
                       where t.poid = p.poid
                         and p.eventid in (:eventid)))
  EOS

  dp.import_table 'JADE', 'MEMBERUPLOADDETAILS', EVENT_FILTER

  dp.import_table 'JADE', 'MEMBERUPLOADDUPLICATEFIELDS', EVENT_FILTER

  dp.import_table 'JADE', 'MEMBERUPLOADEVENTCONFIG', EVENT_FILTER

  dp.import_table 'JADE', 'MEMBERUPLOADQUERIES', EVENT_FILTER

  dp.import_table 'JADE', 'X_ROOMING_LIST_HISTORY', EVENT_FILTER

  dp.import_table 'JADE', 'GROUPBLOCKREQUEST', EVENT_FILTER

  dp.import_table 'JADE', 'GROUPBLOCKREQUESTDATE', <<-EOS
    where exists (select * from jade.groupblockrequest@:sourcedb g
                   where g.requestid = x.requestid
                     and g.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'GROUPBLOCKREQUESTSUITE', <<-EOS
    where exists (select * from jade.groupblockrequest@:sourcedb g
                   where g.requestid = x.requestid
                     and g.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'GROUPBLOCKREQUEST_DATE_SETUP', EVENT_FILTER

  dp.import_table 'JADE', 'GROUPBLOCKREQUEST_EVENTSETUP', EVENT_FILTER

  dp.import_table 'JADE', 'GROUPBLOCKREQUEST_HISTORY', <<-EOS
    where exists (select * from jade.groupblockrequest@:sourcedb g
                   where g.requestid = x.requestid
                     and g.eventid in (:eventid))
  EOS

  dp.import_table 'JADE', 'GROUPBLOCKREQUEST_WELCOME', EVENT_FILTER

  dp.import_table 'JADE', 'GROUPHOUSING_DYNAMIC_TEXT', EVENT_FILTER

  dp.import_table 'JADE', 'PHONENUMBER', <<-EOS
    where exists (select * from jade.personphone@:sourcedb pp
                   where pp.phonenumberid = x.phonenumberid and exists
                     (select * from jade.person_temp_list@:sourcedb_current ptl
                       where pp.personid = ptl.personid))
  EOS

  dp.import_table 'JADE', 'ORGANIZATION', <<-EOS
    where x.organizationid in (select eh.hotelid from jade.eventhotel@:sourcedb eh
                                where eh.eventid in (:eventid)
                               union select a.organizationid from jade.allocation@:sourcedb a
                                where exists (select * from jade.block@:sourcedb b
                                               where a.blockid = b.blockid
                                                 and b.eventid in (:eventid))
                               union select p.organizationid from jade.preapproval@:sourcedb p
                                where p.eventid in (:eventid)
                               union select rc.organizationid from jade.regcap@:sourcedb rc
                                where exists (select * from jade.regtype@:sourcedb rt
                                               where rc.regtypeid = rt.regtypeid
                                                 and rt.eventid in (:eventid))
                               union select p.organizationid from jade.person@:sourcedb p
                                where exists (select * from jade.person_temp_list@:sourcedb_current ptl
                                               where p.personid = ptl.personid))
  EOS

  dp.import_table 'JADE', 'ADDRESS', ADDRESS_FILTER

  dp.import_table 'JADE', 'ADDRESSLATLNG', ADDRESS_FILTER

  dp.import_table 'JADE', 'ONSITE_EVENTSETUP', EVENT_FILTER

  dp.import_table 'JADE', 'ONSITE_PERSPECTIVE', EVENT_FILTER

  dp.import_table 'JADE', 'WEB_SCHEDULE', EVENT_FILTER

  dp.import_table 'JADE', 'STAFF_ROOM_MANAGER', EVENT_FILTER

  dp.import_table 'JADE', 'STAFF_ROOM_REQUEST', EVENT_FILTER

  dp.import_table 'REPORTING', 'PAYPROFLOW', EVENT_FILTER

  dp.import_table 'ONESYSTEMCEU', 'CEU_SESSIONS', EVENT_FILTER

  dp.import_table 'ONESYSTEMCEU', 'CEU_SESSION_SPEAKER', <<-EOS
    where exists (select * from onesystemceu.ceu_sessions@:sourcedb s
                   where x.sessionid = s.sessionid
                     and s.eventid in (:eventid))
  EOS

  dp.import_table 'ONESYSTEMCEU', 'CEU_OBJECT', <<-EOS
    where exists (select * from onesystemceu.ceu_sessions@:sourcedb s
                   where x.sessionid = s.sessionid
                     and s.eventid in (:eventid))
  EOS

  dp.import_table 'ONESYSTEMCEU', 'CEU_SURVEY', EVENT_FILTER

  dp.import_table 'ONESYSTEMCEU', 'CEU_SURVEY_QUESTION', <<-EOS
    where exists (select * from onesystemceu.ceu_survey@:sourcedb s
                   where x.surveyid = s.surveyid
                     and s.eventid in (:eventid))
  EOS

  dp.import_table 'ONESYSTEMCEU', 'CEU_SURVEYMULTICHOICEANSWER', <<-EOS
    where exists (select * from onesystemceu.ceu_survey_question@:sourcedb sq
                   where x.surveyquestionid = sq.surveyquestionid and exists
                     (select * from onesystemceu.ceu_survey@:sourcedb s
                       where sq.surveyid = s.surveyid
                         and s.eventid in (:eventid)))
  EOS

  dp.import_table 'ONESYSTEMCEU', 'CEU_PERSON_SESSION', PERSON_FILTER

  dp.import_table 'ONESYSTEMCEU', 'CEU_PERSON_SURVEYANSWER', PERSON_FILTER

  dp.import_table 'JADE_REPORTS', 'REPORTS_USER_EVENTS', EVENT_FILTER

  dp.import_table 'JADE_REPORTS', 'REPORTS_SUBSCRIPTIONS', EVENT_FILTER

  # Clear contact IDs for events we have not imported.
  dp.post_run <<-EOS
    update jade.person p
       set p.contacttypeid = null
     where not exists (select * from jade.contacttype ct
                        where p.contacttypeid = ct.contacttypeid)
  EOS

  # Remove UDFs for events we have not imported.
  dp.post_run <<-EOS
    delete from jade.personudfvalue puv
     where not exists (select * from jade.userdefinedfield udf
                        where puv.userdefinedfieldid = udf.userdefinedfieldid)
  EOS

  # Remove survey responses for people no longer associated with this event.
  dp.post_run <<-EOS
    delete from jade.person_surveyanswer psa
     where not exists (select * from jade.person p
                        where psa.personid = p.personid)
  EOS

  dp.post_run <<-EOS
    delete from jade.person_surveyanswer_multi psa
     where not exists (select * from jade.person p
                        where psa.personid = p.personid)
  EOS

  # Remove survey responses with answers no longer associated to this event.
  dp.post_run <<-EOS
    delete from jade.person_surveyanswer_multi psam
     where not exists (select * from jade.surveyanswer sa
                        where psam.surveyanswerid = sa.surveyanswerid)
  EOS

  # Disable/repoint credit card processing
  dp.post_run <<-EOS
    update jade.eventpayflowpro
       set test = 'Y'
  EOS

  # Clear unrelated event IDs from BADGEPRINTER and BADGEPRINTER_USER
  dp.post_run <<-EOS
    update jade.badgeprinter
       set eventid = null
     where eventid not in (select eventid from jade.event)
  EOS

  dp.post_run <<-EOS
    update jade.badgeprinter_user
       set eventid = 0
     where eventid not in (select eventid from jade.event)
  EOS

  # Repoint AORN plugin config
  dp.post_run <<-EOS
    update jade.aorn_pluginconfig
       set aorn_soap_url = 'http://staging.aorn.org/WebServices/CongressWCFService.svc'
  EOS

  # Change URLs in confirmations to point to staging.
  dp.post_run <<-EOS
    update jade.confirmation2 x
       set x.processed_template = xmltype(
               replace(x.processed_template.getClobVal(), 'www.wynjade.com', 'staging01.wyndhamjade.com'))
  EOS

  dp.post_run <<-EOS
    update jade.confirmation2_localized x
       set x.processed_template = xmltype(
               replace(x.processed_template.getClobVal(), 'www.wynjade.com', 'staging01.wyndhamjade.com'))
  EOS

  dp.post_run <<-EOS
    update jade.confirmation2 x
       set x.processed_template = xmltype(
               replace(x.processed_template.getClobVal(), 'www.jaderegistration.com', 'staging02.wyndhamjade.com'))
  EOS

  dp.post_run <<-EOS
    update jade.confirmation2_localized x
       set x.processed_template = xmltype(
               replace(x.processed_template.getClobVal(), 'www.jaderegistration.com', 'staging02.wyndhamjade.com'))
  EOS

  dp.post_run <<-EOS
    update jade.confirmation2 x
       set x.processed_template = xmltype(
               replace(x.processed_template.getClobVal(), 'onsite2.jaderegistration.com', 'staging02.wyndhamjade.com'))
  EOS

  dp.post_run <<-EOS
    update jade.confirmation2_localized x
       set x.processed_template = xmltype(
               replace(x.processed_template.getClobVal(), 'onsite2.jaderegistration.com', 'staging02.wyndhamjade.com'))
  EOS

  # TODO: Remove credit card info
  # TODO: Disable/repoint AARP plugin config
end

__END__

# We do not currently import rows for these tables:

AARP_VIP_GUEST
AARP_VIP_HOUSING
AARP_VIP_PAYMENT
AARP_VIP_REGISTRANT
ACEGROUP07
CFPSETUP
CFPSETUP_I18N
CFP_EVENTPERSON
CFP_LOGININFO
CFP_LOGININFO_I18N
CFP_MESSAGEOVERLOAD
CFP_PERSONCOMMENT
CFP_PERSONCONFIRMATION
CFP_PERSONTOPIC
CFP_REQUIREDFIELDS
EBS_BOOTH
EBS_COMPANY
EBS_COMPANY_BOOTH
EBS_EVENT
EBS_PAYMENT
EBS_VERISIGN
ERCC
ERCCRESP
ERCCX
ERCHECK
ERCHECKBATCH
ERCHECKREFUNDRQ
ERCHECKREG
EREVENT
ERLOGIN
ERPNREF
ERREFUNDDETAIL
ERREFUNDINVOICE
ERREFUNDRQ
ERUSERNAME
GOLFER
HDCC
HDCCTYPE
HDCCX
HDCHECK
HDCHECKBATCH
HDCHECKCANCELREFUND
HDCHECKCANCELREFUNDRQ
HDCHECKOVERPAYREFUND
HDCHECKOVERPAYREFUNDRQ
HDCHECKRES
HDEMAIL
HDEVENT
HDFINALCUTOFF
HDFIRSTCUTOFF
HDINVOICEDETAIL
HDINVOICEMASTER
HDLOGIN
HDUSERNAME
HR_ADDRESS
HR_PAYMENT
HR_REFUND
NCTM_CEU_COUNTS
NCTM_CUE
UJC_FEDARATION
