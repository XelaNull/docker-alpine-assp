# Docker Alpine ASSP

This project seeks to create a single-file Dockerfile that can be used to easily recreate an ASSP anti-spam filter. This Dockerfile contains a fully usable ASSP installation that you can easily deploy to a server. This Dockerfile is configured to download the "latest" ASSP and to pre-configure it for use with a Zimbra SMTP server.

- Alpine 3.8
- Supervisor
- cron
- rSyslog
- MariaDB
- Clamav
- Postfix
- OpenDKIM
- ASSP

**To Build:**

```
docker build -t alpine3.8/assp .
```

**To Run:**

```
docker run -d --privileged --name=ALPINE-ASSP -p25:25/tcp -p465:465/tcp -p587:587/tcp -p1025:1025/tcp -p55555:55555/tcp \
 -e MYSQL_ROOT_PASSWORD=YOURPASSWORDHERE -e MYSQL_USER=assp -e MYSQL_USER_PASSWORD=YOURPPASSWORDHERE -e MYSQL_USER_DB=assp -e SKIP_INNODB=true \ 
 -v $(pwd)/var-log:/var/log \ 
 -v $(pwd)/var-lib-mysql:/var/lib/mysql 
 -v $(pwd)/etc-mysql:/etc/mysql \ 
 -v $(pwd)/var-spool-postfix:/var/spool/postfix \ 
 -v $(pwd)/etc-opendkim:/etc/opendkim \ 
 -v $(pwd)/usr-share-assp:/usr/share/assp/ \ 
 alpine3.8/assp
```

**To Access:**

```
http://YOURIP:55555
Username: admin
Password: nospam4me
```

**To Enter:**

```
docker exec -it ALPINE-ASSP bash
```
