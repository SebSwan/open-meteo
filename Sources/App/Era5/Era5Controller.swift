import Foundation
import Vapor


/**
 TODO time arrays in large history responses are very inefficient
 */
struct Era5Controller {
    func query(_ req: Request) -> EventLoopFuture<Response> {
        do {
            // API should only be used on the subdomain
            if req.headers[.host].contains(where: { $0.contains("open-meteo.com") && !$0.starts(with: "archive-api.") }) {
                throw Abort.init(.notFound)
            }
            let generationTimeStart = Date()
            let params = try req.query.decode(Era5Query.self)
            try params.validate()
            let elevationOrDem = try params.elevation ?? Dem90.read(lat: params.latitude, lon: params.longitude)
            
            let allowedRange = Timestamp(1959, 1, 1) ..< Timestamp.now()
            let timezone = try params.resolveTimezone()
            let time = try params.getTimerange(timezone: timezone, allowedRange: allowedRange)
            let hourlyTime = time.range.range(dtSeconds: 3600)
            let dailyTime = time.range.range(dtSeconds: 3600*24)
            
            let domains = params.models ?? [.best_match]
            
            let readers = try domains.compactMap {
                try GenericReaderMulti<CdsVariable>(domain: $0, lat: params.latitude, lon: params.longitude, elevation: elevationOrDem, mode: params.cell_selection ?? .land)
            }
            
            guard !readers.isEmpty else {
                throw ForecastapiError.noDataAvilableForThisLocation
            }

            // Start data prefetch to boooooooost API speed :D
            if let hourlyVariables = params.hourly {
                for reader in readers {
                    try reader.prefetchData(variables: hourlyVariables, time: hourlyTime)
                }
            }
            if let dailyVariables = params.daily {
                for reader in readers {
                    try reader.prefetchData(variables: dailyVariables, time: dailyTime)
                }
            }
            
            
            let hourly: ApiSection? = try params.hourly.map { variables in
                var res = [ApiColumn]()
                res.reserveCapacity(variables.count * readers.count)
                for reader in readers {
                    for variable in variables {
                        let name = readers.count > 1 ? "\(variable.rawValue)_\(reader.domain.rawValue)" : variable.rawValue
                        guard let d = try reader.get(variable: variable, time: hourlyTime)?.convertAndRound(params: params).toApi(name: name) else {
                            continue
                        }
                        assert(hourlyTime.count == d.data.count)
                        res.append(d)
                    }
                }
                return ApiSection(name: "hourly", time: hourlyTime, columns: res)
            }
            let daily: ApiSection? = try params.daily.map { dailyVariables in
                var res = [ApiColumn]()
                res.reserveCapacity(dailyVariables.count * readers.count)
                var riseSet: (rise: [Timestamp], set: [Timestamp])? = nil
                
                for reader in readers {
                    for variable in dailyVariables {
                        if variable == .sunrise || variable == .sunset {
                            // only calculate sunrise/set once
                            let times = riseSet ?? Zensun.calculateSunRiseSet(timeRange: time.range, lat: params.latitude, lon: params.longitude, utcOffsetSeconds: time.utcOffsetSeconds)
                            riseSet = times
                            if variable == .sunset {
                                res.append(ApiColumn(variable: variable.rawValue, unit: params.timeformatOrDefault.unit, data: .timestamp(times.set)))
                            } else {
                                res.append(ApiColumn(variable: variable.rawValue, unit: params.timeformatOrDefault.unit, data: .timestamp(times.rise)))
                            }
                            continue
                        }
                        let name = readers.count > 1 ? "\(variable.rawValue)_\(reader.domain.rawValue)" : variable.rawValue
                        guard let d = try reader.getDaily(variable: variable, params: params, time: dailyTime)?.toApi(name: name) else {
                            continue
                        }
                        assert(dailyTime.count == d.data.count)
                        res.append(d)
                    }
                }
                
                return ApiSection(name: "daily", time: dailyTime, columns: res)
            }
            
            let generationTimeMs = Date().timeIntervalSince(generationTimeStart) * 1000
            let out = ForecastapiResult(
                latitude: readers[0].modelLat,
                longitude: readers[0].modelLon,
                elevation: readers[0].targetElevation,
                generationtime_ms: generationTimeMs,
                utc_offset_seconds: time.utcOffsetSeconds,
                timezone: timezone,
                current_weather: nil,
                sections: [hourly, daily].compactMap({$0}),
                timeformat: params.timeformatOrDefault
            )
            //let response = Response()
            //try response.content.encode(out, as: .json)

            return req.eventLoop.makeSucceededFuture(try out.response(format: params.format ?? .json))
        } catch {
            return req.eventLoop.makeFailedFuture(error)
        }
    }
}

enum CdsDomainApi: String, Codable, CaseIterable, MultiDomainMixerDomain {
    case best_match
    case era5
    case cerra
    case era5_land
    
    /// Return the required readers for this domain configuration
    /// Note: last reader has highes resolution data
    func getReader(lat: Float, lon: Float, elevation: Float, mode: GridSelectionMode) throws -> [any GenericReaderMixable] {
        switch self {
        case .best_match:
            return try Era5Mixer(domains: [.era5, .era5_land], lat: lat, lon: lon, elevation: elevation, mode: mode)?.reader ?? []
        case .era5:
            return try Era5Reader(domain: .era5, lat: lat, lon: lon, elevation: elevation, mode: mode).flatMap({[$0]}) ?? []
        case .era5_land:
            return try Era5Reader(domain: .era5_land, lat: lat, lon: lon, elevation: elevation, mode: mode).flatMap({[$0]}) ?? []
        case .cerra:
            return try CerraReader(domain: .cerra, lat: lat, lon: lon, elevation: elevation, mode: mode).flatMap({[$0]}) ?? []
        }
    }
}

enum CdsVariable: String, Codable, GenericVariableMixable {
    case temperature_2m
    case windgusts_10m
    case dewpoint_2m
    case cloudcover_low
    case cloudcover_mid
    case cloudcover_high
    case pressure_msl
    case snowfall_water_equivalent
    case soil_temperature_0_to_7cm
    case soil_temperature_7_to_28cm
    case soil_temperature_28_to_100cm
    case soil_temperature_100_to_255cm
    case soil_moisture_0_to_7cm
    case soil_moisture_7_to_28cm
    case soil_moisture_28_to_100cm
    case soil_moisture_100_to_255cm
    case shortwave_radiation
    case precipitation
    case direct_radiation
    
    case weathercode
    case apparent_temperature
    case relativehumidity_2m
    case windspeed_10m
    case winddirection_10m
    case windspeed_100m
    case winddirection_100m
    case vapor_pressure_deficit
    case diffuse_radiation
    case surface_pressure
    case snowfall
    case rain
    case et0_fao_evapotranspiration
    case cloudcover
    case direct_normal_irradiance
    
    var requiresOffsetCorrectionForMixing: Bool {
        switch self {
        case .soil_moisture_0_to_7cm:
            fallthrough
        case .soil_moisture_7_to_28cm:
            fallthrough
        case .soil_moisture_28_to_100cm:
            fallthrough
        case .soil_moisture_100_to_255cm:
            return true
        default:
            return false
        }
    }
}

typealias Era5HourlyVariable = VariableOrDerived<Era5Variable, Era5VariableDerived>

enum Era5VariableDerived: String, Codable, RawRepresentableString, GenericVariableMixable {
    case apparent_temperature
    case relativehumidity_2m
    case windspeed_10m
    case winddirection_10m
    case windspeed_100m
    case winddirection_100m
    case vapor_pressure_deficit
    case diffuse_radiation
    case surface_pressure
    case snowfall
    case rain
    case et0_fao_evapotranspiration
    case cloudcover
    case direct_normal_irradiance
    case weathercode
    
    var requiresOffsetCorrectionForMixing: Bool {
        return false
    }
}

enum Era5DailyWeatherVariable: String, Codable {
    case weathercode
    case temperature_2m_max
    case temperature_2m_min
    case apparent_temperature_max
    case apparent_temperature_min
    case precipitation_sum
    case snowfall_sum
    case rain_sum
    case shortwave_radiation_sum
    // cloudcover_total_max?
    case windspeed_10m_max
    case windgusts_10m_max
    case winddirection_10m_dominant
    /// TODO implement aggregation
    //case sunshine_hours
    case precipitation_hours
    case sunrise
    case sunset
    case et0_fao_evapotranspiration
}

struct Era5Query: Content, QueryWithTimezone, ApiUnitsSelectable {
    let latitude: Float
    let longitude: Float
    let hourly: [CdsVariable]?
    let daily: [Era5DailyWeatherVariable]?
    //let current_weather: Bool?
    let elevation: Float?
    //let timezone: String?
    let temperature_unit: TemperatureUnit?
    let windspeed_unit: WindspeedUnit?
    let precipitation_unit: PrecipitationUnit?
    let timeformat: Timeformat?
    let format: ForecastResultFormat?
    let timezone: String?
    let models: [CdsDomainApi]?
    let cell_selection: GridSelectionMode?
    
    /// iso starting date `2022-02-01`
    let start_date: IsoDate
    /// included end date `2022-06-01`
    let end_date: IsoDate
    
    func validate() throws {
        if latitude > 90 || latitude < -90 || latitude.isNaN {
            throw ForecastapiError.latitudeMustBeInRangeOfMinus90to90(given: latitude)
        }
        if longitude > 180 || longitude < -180 || longitude.isNaN {
            throw ForecastapiError.longitudeMustBeInRangeOfMinus180to180(given: longitude)
        }
        guard end_date.date >= start_date.date else {
            throw ForecastapiError.enddateMustBeLargerEqualsThanStartdate
        }
        guard start_date.year >= 1959, start_date.year <= 2030 else {
            throw ForecastapiError.dateOutOfRange(parameter: "start_date", allowed: Timestamp(1959,1,1)..<Timestamp(2031,1,1))
        }
        guard end_date.year >= 1959, end_date.year <= 2030 else {
            throw ForecastapiError.dateOutOfRange(parameter: "end_date", allowed: Timestamp(1959,1,1)..<Timestamp(2031,1,1))
        }
        if daily?.count ?? 0 > 0 && timezone == nil {
            throw ForecastapiError.timezoneRequired
        }
    }
    
    func getTimerange(timezone: TimeZone, allowedRange: Range<Timestamp>) throws -> TimerangeLocal {
        let start = start_date.toTimestamp()
        let includedEnd = end_date.toTimestamp()
        guard includedEnd.timeIntervalSince1970 >= start.timeIntervalSince1970 else {
            throw ForecastapiError.enddateMustBeLargerEqualsThanStartdate
        }
        guard allowedRange.contains(start) else {
            throw ForecastapiError.dateOutOfRange(parameter: "start_date", allowed: allowedRange)
        }
        guard allowedRange.contains(includedEnd) else {
            throw ForecastapiError.dateOutOfRange(parameter: "end_date", allowed: allowedRange)
        }
        let utcOffsetSeconds = (timezone.secondsFromGMT() / 3600) * 3600
        
        return TimerangeLocal(range: start.add(-1 * utcOffsetSeconds) ..< includedEnd.add(86400 - utcOffsetSeconds), utcOffsetSeconds: utcOffsetSeconds)
    }
    
    var timeformatOrDefault: Timeformat {
        return timeformat ?? .iso8601
    }
    
    /*func getUtcOffsetSeconds() throws -> Int {
        guard let timezone = timezone else {
            return 0
        }
        guard let tz = TimeZone(identifier: timezone) else {
            throw ForecastapiError.invalidTimezone
        }
        return (tz.secondsFromGMT() / 3600) * 3600
    }*/
}


extension GenericReaderMulti where Variable == CdsVariable {
    func prefetchData(variables: [Era5DailyWeatherVariable], time timeDaily: TimerangeDt) throws {
        let time = timeDaily.with(dtSeconds: 3600)
        for variable in variables {
            switch variable {
            case .temperature_2m_max:
                fallthrough
            case .temperature_2m_min:
                try prefetchData(variable: .temperature_2m, time: time)
            case .apparent_temperature_max:
                fallthrough
            case .apparent_temperature_min:
                try prefetchData(variable: .temperature_2m, time: time)
                try prefetchData(variable: .windspeed_10m, time: time)
                try prefetchData(variable: .dewpoint_2m, time: time)
                try prefetchData(variable: .shortwave_radiation, time: time)
            case .precipitation_sum:
                try prefetchData(variable: .precipitation, time: time)
            case .shortwave_radiation_sum:
                try prefetchData(variable: .shortwave_radiation, time: time)
            case .windspeed_10m_max:
                try prefetchData(variable: .windspeed_10m, time: time)
            case .windgusts_10m_max:
                try prefetchData(variable: .windgusts_10m, time: time)
            case .winddirection_10m_dominant:
                try prefetchData(variable: .windspeed_10m, time: time)
                try prefetchData(variable: .winddirection_10m, time: time)
            case .precipitation_hours:
                try prefetchData(variable: .precipitation, time: time)
            case .sunrise:
                break
            case .sunset:
                break
            case .et0_fao_evapotranspiration:
                try prefetchData(variable: .shortwave_radiation, time: time)
                try prefetchData(variable: .temperature_2m, time: time)
                try prefetchData(variable: .dewpoint_2m, time: time)
                try prefetchData(variable: .windspeed_10m, time: time)
            case .snowfall_sum:
                try prefetchData(variable: .snowfall_water_equivalent, time: time)
            case .rain_sum:
                try prefetchData(variable: .precipitation, time: time)
                try prefetchData(variable: .snowfall_water_equivalent, time: time)
            case .weathercode:
                try prefetchData(variable: .weathercode, time: time)
            }
        }
    }
    
    func getDaily(variable: Era5DailyWeatherVariable, params: Era5Query, time timeDaily: TimerangeDt) throws -> DataAndUnit? {
        let time = timeDaily.with(dtSeconds: 3600)
        switch variable {
        case .temperature_2m_max:
            guard let data = try get(variable: .temperature_2m, time: time)?.convertAndRound(params: params) else {
                return nil
            }
            return DataAndUnit(data.data.max(by: 24), data.unit)
        case .temperature_2m_min:
            guard let data = try get(variable: .temperature_2m, time: time)?.convertAndRound(params: params) else {
                return nil
            }
            return DataAndUnit(data.data.min(by: 24), data.unit)
        case .apparent_temperature_max:
            guard let data = try get(variable: .apparent_temperature, time: time)?.convertAndRound(params: params) else {
                return nil
            }
            return DataAndUnit(data.data.max(by: 24), data.unit)
        case .apparent_temperature_min:
            guard let data = try get(variable: .apparent_temperature, time: time)?.convertAndRound(params: params) else {
                return nil
            }
            return DataAndUnit(data.data.min(by: 24), data.unit)
        case .precipitation_sum:
            // rounding is required, becuse floating point addition results in uneven numbers
            guard let data = try get(variable: .precipitation, time: time)?.convertAndRound(params: params) else {
                return nil
            }
            return DataAndUnit(data.data.sum(by: 24).round(digits: 2), data.unit)
        case .shortwave_radiation_sum:
            guard let data = try get(variable: .shortwave_radiation, time: time)?.convertAndRound(params: params) else {
                return nil
            }
            // 3600s only for hourly data of source
            return DataAndUnit(data.data.map({$0*0.0036}).sum(by: 24).round(digits: 2), .megaJoulesPerSquareMeter)
        case .windspeed_10m_max:
            guard let data = try get(variable: .windspeed_10m, time: time)?.convertAndRound(params: params) else {
                return nil
            }
            return DataAndUnit(data.data.max(by: 24), data.unit)
        case .windgusts_10m_max:
            guard let data = try get(variable: .windgusts_10m, time: time)?.convertAndRound(params: params) else {
                return nil
            }
            return DataAndUnit(data.data.max(by: 24), data.unit)
        case .winddirection_10m_dominant:
            guard let speed = try get(variable: .windspeed_10m, time: time)?.data,
                let direction = try get(variable: .winddirection_10m, time: time)?.data else {
                return nil
            }
            // vector addition
            let u = zip(speed, direction).map(Meteorology.uWind).sum(by: 24)
            let v = zip(speed, direction).map(Meteorology.vWind).sum(by: 24)
            return DataAndUnit(Meteorology.windirectionFast(u: u, v: v), .degreeDirection)
        case .precipitation_hours:
            guard let data = try get(variable: .precipitation, time: time)?.convertAndRound(params: params) else {
                return nil
            }
            return DataAndUnit(data.data.map({$0 > 0.001 ? 1 : 0}).sum(by: 24), .hours)
        case .sunrise:
            return DataAndUnit([],.hours)
        case .sunset:
            return DataAndUnit([],.hours)
        case .et0_fao_evapotranspiration:
            guard let data = try get(variable: .et0_fao_evapotranspiration, time: time)?.convertAndRound(params: params) else {
                return nil
            }
            return DataAndUnit(data.data.sum(by: 24).round(digits: 2), data.unit)
        case .snowfall_sum:
            guard let data = try get(variable: .snowfall, time: time)?.convertAndRound(params: params) else {
                return nil
            }
            return DataAndUnit(data.data.sum(by: 24).round(digits: 2), data.unit)
        case .rain_sum:
            guard let data = try get(variable: .rain, time: time)?.convertAndRound(params: params) else {
                return nil
            }
            return DataAndUnit(data.data.sum(by: 24).round(digits: 2), data.unit)
        case .weathercode:
            guard let data = try get(variable: .weathercode, time: time)?.convertAndRound(params: params) else {
                return nil
            }
            return DataAndUnit(data.data.max(by: 24), data.unit)
        }
    }
}
