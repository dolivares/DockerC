FROM ubuntu:precise
MAINTAINER Daniel Olivares

# Replace shell with bash so we can source files
RUN rm /bin/sh && ln -s /bin/bash /bin/sh

# Set debconf to run non-interactively
RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections

RUN apt-get update
RUN apt-get install -y -q \
        apt-utils               \
        git                     \
        wget                    \
        curl                    \
        build-essential         \
        libmysqlclient-dev      \
        libssl-dev              \
        libreadline-dev         \
        libxslt1-dev            \
        libxml2-dev             \
        libsqlite3-dev          \
        libcurl4-openssl-dev    \
        zlib1g-dev              \
        libexpat1-dev           \
        libicu-dev              \
        libyaml-dev             \
        m4                      \
        vim                     \
        sudo                    \
        rsync                   \
        unzip                   \
        man-db                  \
        libaio1                 \
        bc                      \
        unixodbc                

RUN apt-get clean

RUN cd /tmp && \
    wget ftp://ftp.ruby-lang.org/pub/ruby/1.9/ruby-1.9.3-p374.tar.gz && \
    tar -xvzf ruby-1.9.3-p374.tar.gz && \
    cd ruby-1.9.3-p374/ && \
    ./configure --prefix=/usr/local && \
    make && \
    make install
RUN gem install bundler

ADD tiller etc/tiller
# ADD configs/oracle_chkconfig /sbin/chkconfig
# ADD configs/oracle_60-oracle.conf /etc/sysctl.d/60-oracle.conf
# RUN chmod 755 /sbin/chkconfig && chmod 0644 /etc/sysctl.d/60-oracle.conf

RUN apt-get install -y rubygems && gem install tiller 

ENV ORACLE_HOME /u01/app/oracle/product/11.2.0/xe
ENV ORACLE_SID XE
ENV ADDITIONAL_SWAP_FILE /var/swapfile
ENV ADDITIONAL_SWAP_SIZE_MB = 2048
ENV LD_LIBRARY_PATH $ORACLE_HOME/lib

RUN tiller -v

RUN service procps start && \
    ln -s /usr/bin/awk /bin/awk && \
    mkdir -p /var/lock/subsys && \
    touch /var/lock/subsys/listener 
    # sudo rm -rf /dev/shm && \
    # mkdir /dev/shm && \
    # mount -t tmpfs shmfs -o size=2048m /dev/shm && \
    # dd if=/dev/zero of=#{ADDITIONAL_SWAP_FILE} bs=1M count=#{ADDITIONAL_SWAP_SIZE_MB} && \
    # chmod 600 #{ADDITIONAL_SWAP_FILE} && \
    # mkswap #{ADDITIONAL_SWAP_FILE} && \
    # swapon -a

ADD http://misc.wyndhamjade.com.s3.amazonaws.com/oracle11g/oracle-xe_11.2.0-2_amd64.deb /usr/local/Downloads/

RUN /etc/init.d/oracle-xe configure responseFile=/tmp/xe.rsp >> /tmp/XEsilentinstall.log
RUN gem install ruby-oci8 ruby-plsql dbi 
RUN $ORACLE_HOME/bin/sqlplus sys/jade as sysdba @/tmp/oracle_users.sql >> /tmp/oracle_users.out && \
    $ORACLE_HOME/bin/sqlplus jadebackup/jade @/tmp/oracle_db_links.sql >> /tmp/oracle_db_links.out
# ADD http://misc.wyndhamjade.com.s3.amazonaws.com/oracle11g/instantclient-basic-linux-x86-64-11.2.0.2.0.zip /usr/local/Downloads/
# ADD http://misc.wyndhamjade.com.s3.amazonaws.com/oracle11g/instantclient-sdk-linux-x86-64-11.2.0.2.0.zip /usr/local/Downloads/

# RUN unzip /usr/local/Downloads/instantclient-basic-linux-x86-64-11.2.0.2.0.zip
# RUN unzip /usr/local/Downloads/instantclient-sdk-linux-x86-64-11.2.0.2.0.zip
# RUN mv instantclient_11_2 /opt/instantclient
# RUN ln -s /opt/instantclient/libocci.so.11.1 /opt/instantclient/libocci.so
# RUN ln -s /opt/instantclient/libclntsh.so.11.1 /opt/instantclient/libclntsh.so


#CMD bash -C 'bash'
CMD ["/bin/bash"]



