*! version 1.0.0 20181220
program define getweather
    version 13.1
	syntax , begindate(string)  enddate(string) latlon(string) [maxdist(integer 10000) numstat(integer 1) weatherinfo(string) working_dir(string) deletefiles(string) delete_gz(string) delete_op(string)]
		
		preserve
		
*Confirming variables exist
*------------------------------------------------------------------------------------------------------------------------------------
		confirm variable `latlon'
		if length("`working_dir'")==0 {
			loc working_dir="`c(pwd)'"
		}
		count if strpos("`latlon'", ",")==0
		
		gen getweath_start_stata=`begindate'
		gen getweath_end_stata=`enddate'

*Confirming user has dependencies installed
*------------------------------------------------------------------------------------------------------------------------------------		
		findfile globdist.ado
		
		if "`r(fn)'" == "" {
				 di as err "package globdist needs to be installed first;"
				 di as txt "use -ssc install globdist- to do that"
				 exit 498
		}
		else if "`r(fn)'" != "" {
				di as txt "package already installed"
				which globdist
		}
		
*Grab list of locations & turn into full panel
*------------------------------------------------------------------------------------------------------------------------------------
		di "  " 
		di "Manipulating variables:" 
		di "  "
	
	`noi' {
		gen getweath_t1 = getweath_start_stata
		gen getweath_t2 = getweath_end_stata 
		gen getweath_id = _n
		gen dif_temp=getweath_t2-getweath_t1+1
		
		expand dif_temp
		drop dif_temp
		sort getweath_id
		
		gen getweath_t = getweath_t1 if _n==1 | getweath_id!=getweath_id[_n-1]
		replace getweath_t = getweath_t[_n-1]+1 if getweath_t==.

*extract year from time variable, create local macro containing each year
*------------------------------------------------------------------------------------------------------------------------------------
		gen getweath_year=year(getweath_t)
		rename getweath_t getweath_date_stata
		
		
		levelsof getweath_year, local(y_list)
		
		loc number_of_years=0
		foreach y in `y_list' {
			snapshot save
			loc r_snapshot=`r(snapshot)'
			keep if getweath_year==`y'
			
			*Allow for at most 3  instances where stations tie for closeness
 			expand (3+`numstat')
 			egen stn_merge_id=seq(), by(`latlon' getweath_date_stata getweath_id)
			
		
			tempfile main_panel`y'
			save "`main_panel`y''", replace
			
			snapshot restore `r_snapshot'
			snapshot erase `r_snapshot'
			loc number_of_years=`number_of_years'+1
		}
	}	
*create local macro containing coordinates of each location in the relevant year
*------------------------------------------------------------------------------------------------------------------------------------
		di "  " 
		di "Creating location coordinate local macros:" 
		di "  "
		
		
		
		duplicates drop `latlon' getweath_year, force	
		keep `latlon' getweath_year
		foreach y in `y_list' {
			 levelsof `latlon' if getweath_year == `y', local(coord_`y')
		}
		
*save list of stations (isd=integrated surface database station history, noaa data) to isd-history.csv				
*------------------------------------------------------------------------------------------------------------------------------------				
		cap confirm "isd-history.csv"
		if _rc!=0 {
			copy "ftp://ftp.ncdc.noaa.gov/pub/data/noaa/isd-history.csv" isd-history.csv
		}
		clear
		import delimited isd-history.csv

	  /* USAF = Air Force station ID. May contain a letter in the first position.
		 WBAN = NCDC WBAN number
		 CTRY = FIPS country ID
		   ST = State for US stations
		 ICAO = ICAO ID
		  LAT = Latitude in thousandths of decimal degrees
		  LON = Longitude in thousandths of decimal degrees
		 ELEV = Elevation in meters
		BEGIN = Beginning Period Of Record (YYYYMMDD). There may be reporting gaps within the P.O.R.
		  END = Ending Period Of Record (YYYYMMDD). There may be reporting gaps within the P.O.R.
		  */
		  rename lat weatherstation_lat
		  rename lon weatherstation_lon

*need to convert numeric vars to string to gen stationid below
*------------------------------------------------------------------------------------------------------------------------------------				
		di "  " 
		di "Generating stationid:" 
		di "  "
		tostring usaf, replace
		tostring wban, replace
		forv i=1(1)5 {
			replace wban="0"+wban if length(wban)<5
		}
		forv i=1(1)6 {
			replace usaf="0"+usaf if length(usaf)<6
		}
		gen stationid=usaf+"-"+wban

*keep station if records at particular station begin before/during the year `y' and end during/after year `y'
*------------------------------------------------------------------------------------------------------------------------------------				
		di "  " 
		di "Dropping stations that aren't active in the relevant year, saving output to stationlist_y:" 
		di "  "
		di "Range: `number_of_years' years"
		foreach y in  `y_list' {
			di "Filtering stations: `y'"
			snapshot save
			loc r_snapshot=`r(snapshot)'
				keep if begin<=(1+`y')*10000 & end>=`y'*10000
				tempfile stationlist_`y'
				save "`stationlist_`y''", replace

			snapshot restore `r_snapshot'
			snapshot erase `r_snapshot'
		}	
		

*------------------------------------------------------------------------------------------------------------------------------------				


*Keep stations that were active + within a user specified radius of the location
*------------------------------------------------------------------------------------------------------------------------------------			
 		di "  " 
		di "Dropping stations that are too far from the location, saving output to keepstationlist_y:" 
		di "  "
		di "Keep only the closest `numstat' station(s) per location:" 
		di "  "
		di "Range: `number_of_years' years"
		
		loc all_missing_y_list=""
		loc non_missing_y_list=""
		foreach y in `y_list' {
			di "Saving keepstationlist_`y'"
 			tempfile keepstationlist_`y' 
			clear
			
*need to gen temp=. otherwise "no variables defined" error
*---------------------------------------------------------				
			gen temp=.
			save `keepstationlist_`y'', replace
			use "`stationlist_`y''", clear

*Manipulate vars to allow globdist to run
*----------------------------------------
			loc no_near_station_list_`y'=""
			foreach l in `coord_`y'' {
 				loc our_lat0=substr("`l'", 1, strpos("`l'", ",")-1)
				loc our_lon0=substr("`l'", strpos("`l'", ",")+1,.)
				snapshot save
				loc r_snapshot=`r(snapshot)'
					
					keep if weatherstation_lat>=(`our_lat0'-(`maxdist'/115)) & weatherstation_lat<=(`our_lat0'+(`maxdist'/115)) 
					*the maximum distance between longitudes is ~111km, at the equator, and shrinks to zero at the poles. maximum distance was used for simplicity as otherwise the whole globdist command would need to be rewritten
					keep if weatherstation_lon>=(`our_lon0'-(`maxdist'/115)) & weatherstation_lon<=(`our_lon0'+(`maxdist'/115)) 
					
					globdist globdist, lat0("`our_lat0'") lon0("`our_lon0'") latvar(weatherstation_lat) lonvar(weatherstation_lon)
					keep if globdist<= `maxdist'
					if _N==0 {
						loc no_near_station_list_`y'="`no_near_station_list_`y''" + " `l'"
					}
					
					if _N!=0 {
						gen `latlon'="`l'"
						append using `keepstationlist_`y''
						save `keepstationlist_`y'', replace
					}
				snapshot restore `r_snapshot'
				snapshot erase `r_snapshot'
			}
			
			
			display "`no_near_station_list_`y''"
			
*local macro containing list of stations that we are interested in
*------------------------------------------------------------------------------------------------------------------------------------				
			use `keepstationlist_`y''
			
			if _N==0 {
				loc all_missing_y_list="`all_missing_y_list'"+ " `y'"
			}
			if _N!=0 {
				loc non_missing_y_list="`non_missing_y_list'" + " `y'"
			cap sort `latlon' globdist 
			
			
*because it doesnt make values of X.5 if they are equidistant but seq does not work with varlist
*------------------------------------------------------------------------------------------------
			egen stationglobdist = rank(globdist), by(`latlon')			
 			replace stationglobdist = floor(stationglobdist)
			replace stationglobdist=stationglobdist[_n-1] if globdist==globdist[_n-1] & `latlon'==`latlon'[_n-1]  

			
*the correct number of stations are kept at all times (regardless of rank being used)
*----------------------------------------------------------------------------------------------------------				
			keep if stationglobdist <= `numstat'
			drop stationglobdist
			levelsof stationid, local(stationid_`y')
			
*for each station the user is interested in, create a full panel with start and end dates
*----------------------------------------------------------------------------------------
			loc y2=`y'+1
			loc leap=date("1-1-`y2'", "MDY") - date("1-1-`y'", "MDY")
			expand `leap' 
			sort stationid `latlon'
			gen getweath_date_stata=date("1-1-`y'", "DMY") if _n==1 | (stationid!=stationid[_n-1] | `latlon'!=`latlon'[_n-1])	
			replace getweath_date_stata=getweath_date_stata[_n-1]+1 if getweath_date_stata==.
			
			tempfile location_station_crosswalk_`y'
			save "`location_station_crosswalk_`y''", replace
			}
			
		}

		
*Read the FTP server and get a list of all stations with history available in each year (stations_`y')
*------------------------------------------------------------------------------------------------------------------------------------				
		di "  " 
		di "Parsing FTP server, recording stations in local macro stations_y:" 
		di "  "
		
		di "Number of years to parse: `number_of_years'"
		foreach y in `non_missing_y_list' {
			di "Parsing year: `y'"
			cap file close test2
			
			cap file open test2 using "ftp://ftp.ncdc.noaa.gov/pub/data/gsod/`y'/" , read
				loc errorcounter=1
				while _rc!=0 & `errorcounter'<=10 {
					display "Error opening file ftp://ftp.ncdc.noaa.gov/pub/data/gsod/`y'/. Retry attemp `errorcounter'/10"
					sleep 1000
					cap file open test2 using "ftp://ftp.ncdc.noaa.gov/pub/data/gsod/`y'/" , read
					loc errorcounter=`errorcounter'+1
				}
				if _rc!=0 {
					display as error "Couldn't open file ftp://ftp.ncdc.noaa.gov/pub/data/gsod/`y'/ at this time."
					exit(0)
				}
			
			file read test2 line
			loc stations_`y'=""
			while r(eof)==0{
				if strpos("`line'", "op.gz") {
					loc stations_`y' = "`stations_`y'';" + substr("`line'", 56,17)
				}
			file read test2 line
			}
      	}
	  
      	

*download the relevant station history data files for each year
*--------------------------------------------------------------
		di "  " 
		di "Downloading station data from FTP server, saving to weatherdata_y:" 
		di "  "
		di "Number of years data to download: `number_of_years'"
		foreach y in `non_missing_y_list' {
			di "Downloading station data: `y'"
			tempfile weatherdata_`y'
			clear
			gen temp=.
			cd "`working_dir'"
			if c(os) == "MacOSX" {
				shell mkdir `y'
				cd "`working_dir'/`y'"
				}
			if c(os) == "Windows" {
				shell mkdir `y'
				loc win_wd="`working_dir'"+"\"+"`y'"
				cd "`win_wd'"
				}
			save "`weatherdata_`y''", replace

			loc stationfound=0

*if "`s'" is found in "`stations'"
*---------------------------------
			foreach s in `stationid_`y'' {
				if strpos( "`stations_`y''", "`s'")!=0 {
							loc stationfound=`stationfound'+1
				
*-cap confirm- so that we can ignore any missing files
*---------------------------------------------------------------------------------------------------------------------------------
					cap confirm file "`s'-`y'.op.gz"
					loc no_gz=_rc!=0
					
					cap confirm file "`s'-`y'.op"
					loc no_op=_rc!=0

					if `no_gz'==1  & `no_op'==1 {
						display "File `s'-`y'.op.gz not found on hard drive. Attempting to download from ftp://ftp.ncdc.noaa.gov/pub/data/gsod/"
						capture quietly ds
						cap copy "ftp://ftp.ncdc.noaa.gov/pub/data/gsod/`y'/`s'-`y'.op.gz" `s'-`y'.op.gz
					
						loc errorcounter=1
						while _rc!=0 & `errorcounter'<=10 {
							display "Error downloading `s'-`y'.op.gz. Retry attemp `errorcounter'/10"
							sleep 1000
							cap copy "ftp://ftp.ncdc.noaa.gov/pub/data/gsod/`y'/`s'-`y'.op.gz" `s'-`y'.op.gz
							loc errorcounter=`errorcounter'+1
						}
						if _rc!=0 {
							display as error "Couldn't download `s'-`y'.op.gz at this time."
							exit(0)
						}
					}

				
					loc downloadcount=`downloadcount'+1
					if c(os) == "MacOSX" & `no_op'==1 {
						shell gunzip `s'-`y'.op.gz
						}
					if c(os) == "Windows" & `no_op'==1 {
						cap shell 7z.exe e -y `s'-`y'.op.gz
					}


					if strlen("`weatherinfo'")==0 {
						loc keepvars "str station 1-6 str wban 8-12 getweath_year 15-18 moday 19-22 MeanTemperature 25-30 MeanTemperatureObs 32-33 MeanDewPoint 36-41 MeanDewPointObs 43-44 MeanSeaPressure 47-52 MeanSeaPressureObs 54-55 MeanStationPressure 58-63  MeanStationPressureObs 65-66  MeanVisibility 69-73 MeanVisibilityobs 75-76 MeanWindSpeed 79-83 MeanWindSpeedObs 85-86 MaxWindSpeed 89-93 Gust 96-100 MaxTemperature 103-108 str MaxTemperatureFlag 109-109 MinTemperature 111-116 str MinTemperatureFlag 117-117 Precipitation 119-123 str PrecipitationFlag 124-124 SnowDepth 126-130 FRSHTT 133-138"
					}
					if strlen("`weatherinfo'")!=0 {
						loc keepvars "str station 1-6 str wban 8-12 getweath_year 15-18 moday 19-22 "

						loc keepvars="`keepvars'" + cond(strpos("`weatherinfo'", "rainfall")!=0, "Precipitation 119-123 str PrecipitationFlag 124-124 ", "")
						loc keepvars="`keepvars'" + cond(strpos("`weatherinfo'", "avgtemp")!=0, "MeanTemperature 25-30 MeanTemperatureObs 32-33 ", "")
						loc keepvars="`keepvars'" + cond(strpos("`weatherinfo'", "dewpoint")!=0, "MeanDewPoint 36-41 MeanDewPointObs 43-44 ", "")
						loc keepvars="`keepvars'" + cond(strpos("`weatherinfo'", "seapressure")!=0, "MeanSeaPressure 47-52 MeanSeaPressureObs 54-55 ", "")
						loc keepvars="`keepvars'" + cond(strpos("`weatherinfo'", "stationpresure")!=0, "MeanStationPressure 58-63  MeanStationPressureObs 65-66 ", "")
						loc keepvars="`keepvars'" + cond(strpos("`weatherinfo'", "visibility")!=0, "MeanVisibility 69-73 MeanVisibilityobs 75-76 ", "")
						loc keepvars="`keepvars'" + cond(strpos("`weatherinfo'", "wind")!=0, "MeanWindSpeed 79-83 MeanWindSpeedObs 85-86 MaxWindSpeed 89-93 Gust 96-100 ", "")
						loc keepvars="`keepvars'" + cond(strpos("`weatherinfo'", "maxtemp")!=0, "MaxTemperature 103-108 str MaxTemperatureFlag 109-109 ", "")
						loc keepvars="`keepvars'" + cond(strpos("`weatherinfo'", "mintemp")!=0, "MinTemperature 111-116 str MinTemperatureFlag 117-117 ", "")
						loc keepvars="`keepvars'" + cond(strpos("`weatherinfo'", "snowdepth")!=0, "SnowDepth 126-130 ", "")
						loc keepvars="`keepvars'" + cond(strpos("`weatherinfo'", "indicators")!=0, "FRSHTT  133-138 ", "")
						

					}
					infix `keepvars' using `s'-`y'.op, clear
					
					drop if station == "STN---"
					
*keep only data that user wants 
*--------------------------------------------------------------------------------------------------
					foreach v of varlist * {
						if strpos("`keepvars'", "`v'")<1 & strlen("`weatherinfo'")>0{
						drop `v'
						}
					}
					
					drop if getweath_year==.
					tostring moday getweath_year, replace
					gen month=substr(moday, 1,length(moday)-2)	
					gen day=substr(moday, length(moday)-1,.)
					gen date=day+"/"+month+"/"+getweath_year
					gen getweath_date_stata=date(date, "DMY")
					drop if getweath_date_stata==.
					gen stationid="`s'"
					duplicates drop
				}
					

				if strpos( "`stations_`y''", "`s'")==0 {
					clear
					loc y2=`y'+1
					loc leap=date("1-1-`y2'", "MDY") - date("1-1-`y'", "MDY")
					set obs `leap'
					gen getweath_date_stata=date("1-1-`y'", "MDY") if _n==1
					replace getweath_date_stata=getweath_date_stata[_n-1]+1 if getweath_date_stata==.
					gen stationid="`s'"
					gen downloadflag="File Missing"
				}

						append using "`weatherdata_`y''"
						save "`weatherdata_`y''", replace
			}	

*merge the noaa gsod data with the location/station crosswalk in each year
*-------------------------------------------------------------------------
			di "Merging station data with location data: `y'" 
			merge 1:m getweath_date_stata stationid using "`location_station_crosswalk_`y''" , force
			
			gen missing_entry_flag="No record from station on this day" if _merge==2
			drop _merge
			


			
 			
*Account for stations which were not found in GSOD ftp server,i.e. a download flag exists
*------------------------------------------------------------------------------------------------------------------------------------				
			
			cap levelsof stationid if downloadflag=="File Missing", local(missingfiles`y')
			
			
			cap replace globdist=99999 if downloadflag=="File Missing"
			
			drop getweath_year month day moday 

	
			*Order stations by globdist, each day
			sort `latlon' getweath_date_stata globdist
			*Gen variable recording this order
			egen stn_merge_id=seq(), by(`latlon' getweath_date_stata)

			merge 1:m `latlon' getweath_date_stata stn_merge_id using "`main_panel`y''" , force
 			gen no_station_flag=""
			foreach missing_latlon in `no_near_station_list_`y'' {
				replace no_station_flag = "No stations within `maxdist' km of this location" if `latlon'=="`missing_latlon'"
			}

 			drop if _merge==1
			drop if stationname=="" & no_station_flag==""
			duplicates drop stationid getweath_date_stata getweath_id, force


			drop  stn_merge_id 
 
			
			tempfile weatherdata_`y'
			save "`weatherdata_`y''", replace
			cd "`working_dir'"
		}
		
		foreach y in `all_missing_y_list' {
			use "`main_panel`y''"
 			
			gen no_station_flag = "No stations within `maxdist' km of this location" if `latlon'=="`missing_latlon'"
			
			duplicates drop  getweath_date_stata getweath_id, force

			tempfile weatherdata_`y'
			save "`weatherdata_`y''", replace
			cd "`working_dir'"
			
		}

		clear
		set obs 0
		gen temp=.
		foreach y in `y_list' {
			append using "`weatherdata_`y''"
		}
		
*drop vars the program generates
*-----------------------------------
		drop temp getweath_start_stata getweath_end_stata getweath_t1 getweath_t2
		loc weathswitch=0
		foreach y in `y_list' {
			if "`missingfiles`y'"!="" {
				display "Station weather data files which seem to be missing from ftp://ftp.ncdc.noaa.gov/pub/data/gsod/`y'/"
				foreach missingstation in "USAF-WBAN" `missingfiles`y''  {
					display "`missingstation'"
					loc weathswitch=1
				}
			}
		}
		if `weathswitch'==1 {
			display as error "Consider increasing the value of MAXDIST for locations without a successful match."
		}
*delete downloaded files if user wishes
*--------------------------------------		
		if strpos("`deletefiles'", "gz")!=0 | strpos("`deletefiles'", "all")!=0 {
			foreach y in `y_list'{
				if c(os) == "MacOSX"{
					cd "`working_dir'/`y'"
					local gz_files : dir "`working_dir'/`y'" files "*.gz"
				}
				if c(os) == "Windows" {
					cd "`working_dir'\`y'"
					local gz_files : dir "`working_dir'\`y'" files "*.gz"
				}
				foreach file in `gz_files' {
					shell rm "`file'"
					di "File removed: `file'"
				}
			}
		}
		if strpos("`deletefiles'", "op")!=0 | strpos("`deletefiles'", "all")!=0 {
			foreach y in `y_list'{
				if c(os) == "MacOSX"{
					cd "`working_dir'/`y'"
					local op_files : dir "`working_dir'/`y'" files "*.op"
				}
				if c(os) == "Windows" {
					cd "`working_dir'\`y'"
					local op_files : dir "`working_dir'\`y'" files "*.op"
				}
				foreach file in `op_files' {
					shell rm "`file'"
					di "File removed: `file'"
				}
			}
		}
		
		if strpos("`deletefiles'", "isd-history")!=0 | strpos("`deletefiles'", "all")!=0 {
			if c(os) == "MacOSX"{
					cd "`working_dir'"
					local isd_files : dir "`working_dir'" files "isd-history.csv"
				}
				if c(os) == "Windows" {
					cd "`working_dir'"
					local isd_files : dir "`working_dir'" files "isd-history.csv"
				}
				
				foreach file in `isd_files' {
					shell rm "`file'"
					di "File `file' removed"
					}
		}
		
		restore , not
end
