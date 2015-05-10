FROM ubuntu:precise
MAINTAINER Daniel Olivares

# Replace shell with bash so we can source files
RUN rm /bin/sh && ln -s /bin/bash /bin/sh

# Set debconf to run non-interactively
RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections

# Install base dependencies
RUN apt-get update && apt-get install -y -q --no-install-recommends \
        apt-transport-https \
        build-essential \
        ca-certificates \
        curl \
        git \
        git-core \
        libssl-dev \
        libaio1 \
        python \
        vim \
        sudo \
        rsync \
        software-properties-common \
        wget \
        unzip \
        man-db \
        libaio1 \
        libxml2-dev \
    && rm -rf /var/lib/apt/lists/* 

ADD http://misc.wyndhamjade.com.s3.amazonaws.com/oracle11g/instantclient-basic-linux-x86-64-11.2.0.2.0.zip /usr/local/Downloads/
ADD http://misc.wyndhamjade.com.s3.amazonaws.com/oracle11g/instantclient-sdk-linux-x86-64-11.2.0.2.0.zip /usr/local/Downloads/

RUN unzip /usr/local/Downloads/instantclient-basic-linux-x86-64-11.2.0.2.0.zip
RUN unzip /usr/local/Downloads/instantclient-sdk-linux-x86-64-11.2.0.2.0.zip
RUN mv instantclient_11_2 /opt/instantclient
RUN ln -s /opt/instantclient/libocci.so.11.1 /opt/instantclient/libocci.so
RUN ln -s /opt/instantclient/libclntsh.so.11.1 /opt/instantclient/libclntsh.so

ENV PATH /home/docker/bin:$PATH
ENV DATABASE_URL oracle://jade:jade@10.10.10.200:1521/xe
ENV NVM_DIR /home/docker/.nvm
ENV NODE_VERSION 0.10.25
#ENV OCI_INCLUDE_DIR /usr/local/instantclient/sdk/include/
#ENV OCI_LIB_DIR /usr/local/instantclient/
#ENV LD_LIBRARY_PATH /user/local/instantclient/
# Setup home environment
RUN mkdir -p /home/docker && \
#	groupadd -r docker -g 433 && \
	useradd -r -d /home/docker -s /sbin/nologin -c "Docker image user" docker && \
#RUN mkdir /home/docker && 
#	chown -R docker:docker /home/docker && \
	mkdir -p /home/docker/bin /home/docker/src /home/docker/lib /home/docker/include && \
    echo 'docker:docker' |chpasswd && adduser docker sudo
RUN adduser docker sudo

ADD configs/.bashrc /home/docker/.bashrc
ADD configs/node-inspectorrc /etc/

#RUN chown -R `whoami` /home/docker/.npm
#RUN chown -R docker/docker $HOME
#RUN chmod 0644 $HOME/nodejs.sh
RUN chmod 755 /home/docker/.bashrc
RUN chmod 755 -R /home/docker/
RUN usermod -u 1000 docker

#ENV GOPATH /home/docker/go:$GOPATH

#ENV HOME /home/docker
#RUN useradd docker && echo 'docker:docker' | chpasswd
#RUN echo "docker ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
WORKDIR /home/docker/src
ENV HOME /home/docker

#ADD configs/nodejs.sh $HOME/


#RUN chown -R docker: /home/docker


# Install nvm with node and npm
RUN curl https://raw.githubusercontent.com/creationix/nvm/v0.25.0/install.sh | bash \
    && source $NVM_DIR/nvm.sh \
    && nvm install $NODE_VERSION \
    && npm update npm -g \
    && npm install -g node-inspector \
    && npm install -g nodemon \
    && npm install -g npm-install-missing 

ENV NODE_PATH $NVM_DIR/v$NODE_VERSION/lib/node_modules
ENV PATH      $NVM_DIR/v$NODE_VERSION/bin:$PATH
RUN chown -R docker:docker /home/docker
USER docker
EXPOSE 3000

#CMD bash -C 'bash'
CMD ["/bin/bash"]



