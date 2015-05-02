
# Pull base image
FROM ubuntu:precise

# Install Redis
RUN apt-get update && apt-get install -y redis-server

# Expose ports locally on VM
EXPOSE 6379

# Define default command.
ENTRYPOINT  ["/usr/bin/redis-server"]
