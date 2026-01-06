"""
Airflow 3.0.2 compatible local settings
This replaces the Helm chart's default which has incompatible imports
"""

# Empty config - no UIAlert imports needed for basic setup
# You can add custom configurations here later

from airflow.configuration import conf

# Example: Configure logging (optional)
# LOGGING_CONFIG = {...}

# Example: Custom security settings (optional)
# from airflow.www.security import AirflowSecurityManager
# SECURITY_MANAGER_CLASS = AirflowSecurityManager


#Okay