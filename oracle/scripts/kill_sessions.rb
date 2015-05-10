#!/usr/bin/env ruby
# Drop JADE user connections to oracle server
#
#
require 'dbi'
require 'ruby-plsql'

$dbh = DBI.connect('dbi:OCI8:','jade','jade')

def foo(username)
  rs = $dbh.execute <<-EOS, username
    select sid, serial# from v$session where username = ?
  EOS
end

$my_sid = "%.0f" % $dbh.select_one("select sys_context('USERENV','SID') from dual");
#puts $my_sid

rs = foo('JADE')
rs.each do |row|
  sid = "%.0f" % row['SID']
  if (sid != $my_sid)
    serial_num = "%.0f" % row['SERIAL#']
    sqlSessionAlter = "alter system kill session \' ? , ? \'"
    puts %{alter system kill session \'#{sid.to_i},#{serial_num.to_i}\'}
    $dbh.do %{alter system kill session \'#{sid.to_i},#{serial_num.to_i}\'}
  end
end
$dbh.commit
$dbh.disconnect


