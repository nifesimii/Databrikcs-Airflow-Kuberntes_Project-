"""
Example DAG for Airflow 3.0.2
Demonstrates TaskFlow API with proper imports
"""
import time
from datetime import datetime
from airflow import DAG
from airflow.decorators import task
from airflow.operators.bash import BashOperator

with DAG(
    dag_id='example_dag',
    start_date=datetime(2024, 1, 1),
    schedule='@daily',
    catchup=False,
    tags=['example', 'airflow-3'],
) as dag:
    
    @task
    def hello_world():
        time.sleep(5)
        print("Hello World, from Airflow 3.0.2!")
        return "Task completed successfully"
    
    def goodbye_world():
        time.sleep(5)
        print("Goodbye world, from Airflow!")
    # Call the task
    hello_world() >> goodbye_world()