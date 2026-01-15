FROM jenkins/jenkins:lts

# Jenkins configurations
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"
ENV CASC_JENKINS_CONFIG="/var/jenkins_home/casc.yaml"

# Default password for the initial deployment
ENV JENKINS_ADMIN_PASSWORD="admin123"

# Copy the plugin list
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt

# Install plugins using the plugin manager CLI
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Copy the configuration files into the container
COPY casc.yaml /var/jenkins_home/casc.yaml
COPY jobs/seed.groovy /var/jenkins_home/seed.groovy
