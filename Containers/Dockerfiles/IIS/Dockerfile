# Sample Dockerfile

# Indicates that the windowsservercore image will be used as the base image.
FROM microsoft/windowsservercore

# Metadata indicating an image maintainer.
MAINTAINER drmiru@hotmail.com

# Uses dism.exe to install the IIS role.
RUN dism.exe /online /enable-feature /all /featurename:iis-webserver /NoRestart

# Creates an HTML file and adds content to this file.
RUN echo "Hello Experts @ Expertslive!" > c:\inetpub\wwwroot\index.html

# Sets a command or process that will run each time a container is run from the new image.
CMD [ "powershell" ]