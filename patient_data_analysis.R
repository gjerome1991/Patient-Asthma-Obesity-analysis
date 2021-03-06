# Import necessary packages
library(ggplot2)
library(dplyr)
library(sqldf)
library(lubridate)
library(scales)

#Function to calculate age later

age <- function(dob, age.day = today(), units = "years", floor = TRUE) {
  calc.age = interval(dob, age.day) / duration(num = 1, units = units)
  if (floor) return(as.integer(floor(calc.age)))
  return(calc.age)
}

# Set working directory
setwd("/Users/geoffrey.kip/Projects/R patient data/patient_data")
getwd()

# Read all csvs in
condition_occurence <- read.csv("condition_occurrence.csv", stringsAsFactors = FALSE)
drug_exposure <- read.csv("drug_exposure.csv",stringsAsFactors=FALSE)
measurement <- read.csv("measurement.csv", stringsAsFactors=FALSE)
persons <- read.csv("person.csv" , stringsAsFactors=FALSE)
visit_occurence <- read.csv("visit_occurrence.csv" , stringsAsFactors=FALSE)
asthma_codeset <- read.csv("asthma_codeset.csv", stringsAsFactors=FALSE)
albuterol_codes <- read.csv("albuterol_codes.csv" , stringsAsFactors=FALSE)
concept <- read.csv("concept.csv" , stringsAsFactors=FALSE )

# Use dplyr package to create filter datasets for asthma, drugs and obese conditions
asthma_conditions <-left_join(condition_occurence, concept, by = c("condition_concept_id" = "concept_id")) %>%
                  select(person_id,
                        condition_concept_id,
                        condition_start_date,
                        concept_name,
                       visit_occurrence_id) %>%
                 filter(grepl('asthma', concept_name))
asthma_conditions = rename(asthma_conditions, concept_id = condition_concept_id, asthma_start_date = condition_start_date,
                           asthma_type = concept_name)

asthma_drugs <- left_join(drug_exposure, albuterol_codes, by = c("drug_concept_id" = "concept_id")) %>%
              select(person_id,
                     drug_concept_id,
                     drug_exposure_start_date,
                     concept_name,
                     visit_occurrence_id) %>%
              filter(!is.na(concept_name))
asthma_drugs = rename(asthma_drugs, concept_id = drug_concept_id, drug_name = concept_name)

obese_conditions <- left_join(measurement, concept, by = c("measurement_concept_id" = "concept_id")) %>%
                 select(person_id,
                        measurement_concept_id,
                        measurement_date,
                        concept_name,
                        value_as_number,
                        visit_occurrence_id) %>%
                  filter(concept_name == "BMI for age z score NHANES 2000" & value_as_number >= 1.645)
obese_conditions = rename(obese_conditions, concept_id = measurement_concept_id, BMI_z_score = concept_name,
                         BMI_measurement_value = value_as_number)

# Use sqldf to create full patient cohort data
sql="WITH
  patient_cohort AS (
SELECT
conditions.person_id,
conditions.visit_occurrence_id,
visits.visit_start_date,
asthma_conditions.asthma_type AS asthma_type,
asthma_conditions.asthma_start_date AS asthma_start_date,
drugs.drug_name AS drug_name,
drugs.drug_exposure_start_date AS drug_start_date,
obese.BMI_z_score AS BMI_zscore,
obese.measurement_date AS BMI_measurement_date,
obese.BMI_measurement_value AS BMI_measurement_value
FROM
condition_occurence AS conditions
LEFT JOIN
asthma_conditions AS asthma_conditions
ON
conditions.visit_occurrence_id = asthma_conditions.visit_occurrence_id
LEFT JOIN
asthma_drugs AS drugs
ON
conditions.visit_occurrence_id = drugs.visit_occurrence_id
LEFT JOIN
obese_conditions AS obese
ON
conditions.visit_occurrence_id = obese.visit_occurrence_id
LEFT JOIN
visit_occurence AS visits
ON
conditions.visit_occurrence_id = visits.visit_occurrence_id
WHERE
asthma_conditions.asthma_type IS NOT NULL
AND drugs.drug_name IS NOT NULL
AND obese.BMI_z_score IS NOT NULL AND obese.measurement_date >= asthma_conditions.asthma_start_date
AND drugs.drug_exposure_start_date >= asthma_conditions.asthma_start_date
ORDER BY
conditions.person_id,
visit_start_date)
SELECT
patient_cohort.person_id,
patient_cohort.visit_occurrence_id,
patient_cohort.visit_start_date,
patient_cohort.asthma_type,
patient_cohort.asthma_start_date,
asthma_unique_visits,
patient_cohort.drug_name,
patient_cohort.drug_start_date,
patient_cohort.BMI_zscore,
patient_cohort.BMI_measurement_date,
patient_cohort.BMI_measurement_value
FROM
patient_cohort
LEFT JOIN (
SELECT
person_id,
COUNT(DISTINCT visit_start_date) AS asthma_unique_visits
FROM
patient_cohort
WHERE
asthma_type IS NOT NULL
GROUP BY
person_id) AS asthma_visits
ON
patient_cohort.person_id = asthma_visits.person_id
WHERE
asthma_unique_visits >= 2 
ORDER BY
patient_cohort.person_id,
visit_start_date"

patient_cohort = sqldf(sql)

#further aggregations

patient_aggregates1 <- patient_cohort %>%
  group_by(person_id) %>%
  summarise(date_of_first_asthma_diagnosis=min(asthma_start_date),
            asthma_unique_visits = max(asthma_unique_visits),
            date_of_first_albuterol_prescription = min(drug_start_date),
            date_of_first_obesity_measurement = min(BMI_measurement_date),
            first_bmi_measurement= first(BMI_measurement_value),
            total_number_of_obesity_values = n_distinct(BMI_measurement_value)) 

# calculate date difference variable
patient_aggregates1$days_between_asthma_diagnosis_and_albuterol_prescription <- 
  as.Date(patient_aggregates1$date_of_first_albuterol_prescription)-
  as.Date(patient_aggregates1$date_of_first_asthma_diagnosis)

# Create persons dataset with race ethnicity and gender

sql2="SELECT
  persons.person_id,
gender.gender,
race.race,
ethnicity.ethnicity,
persons.birth_datetime
FROM (
SELECT
persons.person_id,
gender_concept_id,
race_concept_id,
ethnicity_concept_id,
birth_datetime
FROM
persons
WHERE
person_id IN (
SELECT
DISTINCT person_id
FROM
patient_cohort)) AS persons
LEFT JOIN (
SELECT
concept_id,
concept_name AS gender
FROM
concept) AS gender
ON
persons.gender_concept_id = gender.concept_id
LEFT JOIN (
SELECT
concept_id,
concept_name AS race
FROM
concept) AS race
ON
persons.race_concept_id = race.concept_id
LEFT JOIN (
SELECT
concept_id,
concept_name AS ethnicity
FROM
concept) AS ethnicity
ON
persons.ethnicity_concept_id = ethnicity.concept_id
"
persons_derived = sqldf(sql2)

# Calculate age

persons_derived$age <- age(persons_derived$birth_datetime)
persons_derived$birth_datetime <- NULL

# Join on the aggregates information to Persons derived table to create table1

persons_table <- left_join(persons_derived, patient_aggregates1, by = c("person_id"))

write.csv(persons_table, "/Users/geoffrey.kip/Projects/R patient data/patient_data/persons_table1.csv")

# Get all inpatient visits

person_inpatient_visits <- inner_join(persons,visit_occurence, by = "person_id") %>%
               select(person_id,
                      visit_start_date,
                      visit_concept_id) %>%
               filter(person_id %in% patient_cohort$person_id & visit_concept_id == 9201)

person_inpatient_visits$visit_concept_id <- NULL

write.csv(person_inpatient_visits, "/Users/geoffrey.kip/Projects/R patient data/patient_data/person_inpatient_visits.csv")

# ALL BMI measurements for a person

persons_bmi_measurements <- left_join(persons_table,measurement, by = "person_id") %>%
  select(person_id,
         age,
         gender,
         measurement_date,
         value_as_number,
         measurement_concept_id) %>%
  filter(person_id %in% patient_cohort$person_id & measurement_concept_id == 2000000043) %>%
  arrange(person_id,measurement_date)

persons_bmi_measurements$measurement_concept_id <- NULL

write.csv(persons_bmi_measurements, "/Users/geoffrey.kip/Projects/R patient data/patient_data/persons_bmi_measurements.csv")

# Do some graphs and tables using ggplot

gender_summary <- persons_table %>%
  group_by(gender) %>%
  summarise(value = n_distinct(person_id))

# Average BMI measurements by gender and age
gender_age_bmi_summary <- persons_bmi_measurements %>%
                         group_by(age,gender) %>%
                         summarise(average_bmi_value = mean(value_as_number))

write.csv(gender_age_bmi_summary, "/Users/geoffrey.kip/Projects/R patient data/patient_data/gender_age_bmi_summary.csv")

ggplot(gender_age_bmi_summary, aes(x = age, y= average_bmi_value, fill = gender)) +
  geom_bar(stat="identity", width=.5, position = "dodge")  +
  xlab("Age Group") +
  ylab("BMI value")

# Find the average first_bmi_measurement for difference races and gender
race_bmi_summary <- persons_table %>%
  group_by(race) %>%
  summarise(average_first_bmi_measurement = mean(first_bmi_measurement))

write.csv(race_bmi_summary, "/Users/geoffrey.kip/Projects/R patient data/patient_data/race_bmi_summary.csv")

gender_bmi_summary <- persons_table %>%
  group_by(gender) %>%
  summarise(average_first_bmi_measurement = mean(first_bmi_measurement))

write.csv(gender_bmi_summary, "/Users/geoffrey.kip/Projects/R patient data/patient_data/gender_bmi_summary.csv")

# Number of Patients by Unique Asthma Visits
ggplot(persons_table, aes(x = asthma_unique_visits)) +
  geom_histogram(colour="black", fill="cadetblue", bins=6) +
  xlab("Total Number of Unique Asthma Visits") + ylab("Number of Patients")

# Plot filled bar chart of race and gender

# ggplot(persons_table, aes(race)) + 
#   geom_bar(aes(fill = gender)) +
#   theme(axis.text.x = element_text(colour="grey40", size=12, angle=90, hjust=.5, vjust=.5),
#         text = element_text(size=10)) +
#   xlab("Race")

ggplot(persons_table, aes(x = race)) +  
  geom_bar(aes(y = (..count..)/sum(..count..)), fill="cadetblue") + 
  scale_y_continuous(labels=percent) +
  theme(axis.text.x = element_text(colour="grey40", size=12, angle=90, hjust=.5, vjust=.5),
        text = element_text(size=10)) +
  ylab("Percent")

