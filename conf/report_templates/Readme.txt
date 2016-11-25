PositioNZ-PP results
====================

Disclaimer: Land Information New Zealand (LINZ) does not provide a warranty of 
any kind with respect to the accuracy of these results.  In no event shall LINZ
be liable for loss of any kind whatsoever with respect to the use of these
results.

Note particularly that the formal errors calculated for coordinates are likely 
to be optimistic, as they do not account for unmodelled systematic errors, 
or errors not represented in the GNSS data (such as plumbing errors and 
antenna heighting errors).

Each RINEX file submitted to the PositioNZ-PP service is processed separately.
The coordinates are calculated in the ITRF2008 reference frame at the epoch of
observation.  The final coordinates are converted to NZGD2000 coordinates at 
nominal epoch 2000.0.

For each file the GPS processing includes the following steps:
  * Approximate point position solution to determine the station location
  * Selection of three PositioNZ reference stations to process with the 
    user station
  * Calculation of the reference station ITRF2008 epoch coordinates
  * Detecting cycle slips and gross errors
  * Resolving ambiguities
  * Calculation of a minimum constraints solution
  * Constraining the solution to fit the reference station coordinates
    (generates the final coordinate for the user station)
  * Converting the coordinate to an ITRF96 epoch coordinate, and then
    applying the NZGD2000 deformation model to determine the NZGD2000 
    coordinate.

The processing is carried out using the Bernese 5.2 GNSS processing software.

Note that some modifications may be made to the submitted RINEX file.  These
are:
  1) The station mark name may be changed to ensure that it is a four character
     code that differs from all PositioNZ CORS station codes.
  2) The receiver type may be changed to one recognised by the software.  
     The software will select a receiver type that appears similar to that
     specified in the RINEX file.
Neither of these changes will significantly affect the coordinates calculated.

Where appropriate the supplied name for the mark is included in the results, but
in most of the processing results the calculated four character code is used.

The following files may be supplied with the processing results.

================================================================================
summary.txt - summary of RINEX file processing

The summary file compiles the results of processing each RINEX file submitted 
to the job. For each file successfully processed the following information is 
included:

Orbit type:  

    This is the quality of satellite orbit information used to process the
    results, one of ultra rapid, rapid, or final.  PositioNZ-PP will use the
    best orbit information available when the job is processed.

Final coordinates

    These are the coordinates calculated by constraining the PositioNZ reference 
    stations. These are presented in two blocks:  

    "Epoch coordinates" are coordinates of the mark at the observation epoch.  
    These are presented in terms of the ITRF2008 and ITRF96 reference frames 
    (note that NZGD2000 is aligned with ITRF96).  

    "NZGD2000 coordinates" are the coordinates at nominal epoch 2000. These 
    have been corrected to nominal epoch 2000.0 using the NZGD2000 
    deformation model. (Note that because the deformation model includes
    "reverse patches" the NZGD2000 coordinate of a mark does not necessarily
    represent where the mark was at epoch 2000.0)

    The NZGD2000 coordinates are also presented as New Zealand Transverse
    Mercator (NZTM2000) coordinates and in one or more meridional circuit 
    projections (based on the location of the mark).  This block also 
    includes the NZVD2016 height - the height above the NZ Quasigeoid 2016 - 
    which approximates an orthometric height.  All other heights are 
    ellipsoidal heights.

XYZ covariance matrix and ENU errors

    These represent the formal error calculated for the final coordinates. As
    noted above these are likely to be optimistic.  The XYZ covariances 
    represent the covariances of the geocentric XYZ coordinates.  The ENU 
    errors are the standard errors of the east, north, and up component 
    determined from the covariance.

    Note that these are apriori covariances and standard errors.  To obtain 
    aposteriori values multiply by the standard error of unit weight (SEUW)
    for standard errors, or the square of the SEUW for covariances.

Processing summary (for minimum constraints solution)

    This contains the statistical information from the final minimal constraints
    solution.  

    In particular the standard error of unit weight (SEUW) represents how well
    the observations fitted in the final adjustment.  Large values for the 
    SEUW may be indicative of problems in the data.  The SEUW may be used
    to scale the coordinate standard errors to obtain aposteriori values.

Reference stations

    The minimum constraints solution is fitted to the three PositioNZ 
    reference stations using a best fitting translation (XYZ shift).  The 
    residual errors at each station provide the most realistic measure of
    the accuracy of the solution (excluding plumbing and antenna height 
    errors).  For each reference table the table lists the code for the 
    mark, the distance in kilometres from the observation station to the
    reference station, and the residual horizontal and vertical errors.

================================================================================
coordinates.csv - summary of calculated coordinates

The coordinates.csv file contains the final coordinates for all the RINEX files
submitted.  It contains the following columns:

mark           The user supplied name for the mark 
datafile       The name of the RINEX file
date           The UTC date and time of the start of the observation session
itrf2008_X     The ITRF2008 X,Y,Z epoch coordinate (metres)
itrf2008_Y
itrf2008_Z
itrf96_X       The ITRF96 X,Y,Z epoch coordinate (metres)
itrf96_Y
itrf96_Z
err_e          The apriori error in the east, north, and up direction (metres)
err_n
err_u
corr_en        The correlation of the east and north errors
corr_eu        The correlation of the east and up errors
corr_nu        The correlation of the north and up errors
seuw           The standard error of unit weight from the final adjustment

================================================================================
NZGD2000.csv - NZGD2000 coordinates in various coordinate systems

The NZGD2000.csv file contains the final coordinates for all the RINEX files
submitted expressed as NZGD2000 coordinates at nominal epoch 2000.0.  Each
file is represented by several rows, each in a different coordinate system.
The columns in the file are:

mark            The user supplied mark name
datafile        The name of the RINEX file
date            The date of the observation (not the date of the coordinate)
coordsys        A code identifying the coordinate system
east            The east/longitude coordinate
north           The north/latitude coordinate
ell_height      The NZGD2000 ellipsoidal height 
nzvd2016_height The NZVD2016 height (height above NZGeoid2016)

================================================================================
xxxxx.kml - KML file for plotting the marks and baselines used

The KML file is a GIS format file that can be used to spatially represent the 
stations and baselines used in the processing.  Most GIS products can import
and display KML formatted files.

================================================================================
final_xxxx.snx - SINEX file of final coordinate calculation

There is one final SINEX file for each input file that is successfully
processed.  The SINEX format is a standard format for representing the 
results of GNSS processing.  Note that this file has been filtered to only
contain the covariance information for the mark coordinates - it does not
include information about other parameters in the adjustment such as 
tropospheric delay parameters.


================================================================================
min_xxxx.snx - SINEX file of the minimally constrained solution

There is one minimally constrained solution SINEX file for each input file that 
is successfully processed. This defines the calculated coordinates and their
covariances for the user mark and the reference PositioNZ reference stations.

================================================================================
rinex_files_x.txt - RINEX file metadata for the observations used

There is one RINEX file metadata summary for each input file.  This includes
summary information about the contents of the input data (including that 
from the submitted RINEX file and that from the PositioNZ reference stations).

