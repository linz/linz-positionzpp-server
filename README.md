PositioNZ-PP server
===================

This repository contains the implementation of the PositioNZ-PP backend 
server.  This is a perl script to manage and run PositioNZ-PP jobs.  It
also manages a number of maintenance tasks related to the service.  

The output of positionzpp --help is listed below.  Most commands must be
run as user positionzpp_server, eg

   sudo -u positionzpp_server positionzpp update_refdata

```

Name
    positionzpp - manages the PositioNZ-PP server backend processes. Also
    used by the cronjob to initiate the server processes.

Synopsis
       positionzpp run <serverid>
       positionzpp update_refdata
       positionzpp run_maintenance
       positionzpp status
       positionzpp data_sources
       positionzpp pause <pause-time> <wait-time>
       positionzpp start
       positionzpp stop <wait-time>
       positionzpp run_test <input-zip> <test-dir>

    Most commands must be run by the positionzpp server user, ie

       sudo -u <positionz_server_user> positionzpp ...

Description
    The PositioNZ-PP Bernese post processing service is implemented by
    initiating server jobs which upload for new jobs and run the processor
    on the jobs that have been loaded. The positionzpp script is used to
    install the crontab running the jobs, as well as being used by the
    crontab to actually run the jobs.

    The processor is designed to interface with a web server front end using
    three shared directories (possibly shared via a separate replication
    process). The directories are:

    input
        The directory to which the front end process uploads jobs. Jobs are
        removed from here by the processor.

    output
        The directory to which the processor uploads results for consumption
        by the front end. It is the responsibility of the front end to
        remove the output files. Each job may create several output files
        during its processing (for example if it needs to wait for GNSS
        reference data)

    refdata
        The directory to which the processor uploads reference data that the
        front end can use. Currently this is used to upload lists of valid
        antennae and receivers. The reference data is overwritten by this
        script. It does not need to be removed.

    The locations of these directories is defined in the positionzpp
    configuration file (/etc/positionzpp/positionzpp.conf).

    The positionzpp script takes the following options on the command line.
    Many can only be run by the positionzpp server user. ie sudo -u
    positionzpp_server positionzpp <commands>.

    run <serverid>
        Runs the server process. This will fail if the the current user is
        not positionzpp server user as defined in the /etc/positionzpp/user
        file.

    update_refdata
        Updates the reference data installed in the interface

    run_maintenance
        Runs miscellaneous maintenance tasks on the processor directories,
        for example removing archived jobs that for which the retention date
        has passed.

    status
        Prints out the current state of the processor

    data_sources
        Prints out a list of the configured data sources

    pause <pause-time> <wait-time>
        Stops the processor for running for a number of seconds. The pause
        time is the number of seconds to pause for. The wait time is the
        maximum time that the program will wait for processes to stop. Both
        times are in seconds. The server is still running while it is
        paused, but it doesn't do anything! Use a pause time of 0 to cancel
        the pause (ie in effect restart the server).

    start
        Starts the PostioNZ-PP backend by installing the crontab in
        /etc/positionzpp/crontab. (Also can be used to reinstall the
        crontab, for example after modifying it).

    stop <wait-time>
        Stops the server by removing the crontab. It will wait the specified
        time for the server processes to halt before returning.

    run_test <input-zip> <test-dir>
        Runs a test server. input-zip is an input job file created by the
        frontend server. test-dir is the name of the directory where the
        test job will run. This is created by the test run and cannot
        already exist. By default it is the base name of the input zip file.

Files
    /etc/positionzpp/user
        File containing just the name of the user that should run the
        processor jobs

    /etc/positionzpp/crontab
        The crontab that is installed by this script.

    /etc/positionzpp/positionzpp.conf
        The main positionz configuration file

    /etc/bernese52/getdata.conf
        The configuration file for the GNSS reference data sources (eg orbit
        data, reference station data etc)

See also:
    LINZ::PNZPP POD documentation for code implementing positionzpp server
    LINZ::BERN POD documentation for modules handling Bernese functions (eg
    creating campaigns, running PCF, etc).
    LINZ::GNSS POD documentation for GNSS code (accessing reference data)
    LINZ::Geodetic Implementation of coordinate conversions and station
    prediction models
```
