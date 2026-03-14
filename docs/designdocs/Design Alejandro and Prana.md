<div align="center">

Driver Drowsiness Detection

Group 8

Pranav Jha • Alejandro Melo-Elizalde • Jason Waseq Pravin Agrawal-Chung • Ricardo Diaz Fuentes • Soham Jain

</div>

Table of Contents
1. Title Page

2. Table of Contents

3. Introduction

3.1 Need & Goal Statements

4.1. Personas

4.1. Truck Driver Persona (Mike Dunford)

4.2. Fleet Operator Persona (Sarah Porter)

5. Existing Designs & Products Research

6. Sustainability Statement

7. Design Features

7.1. Driver Monitoring Features

7.2. Alert and Safety Features

7.3. Mobile App Features

7.4. Fleet Management Features

7.5. System Architecture

8. Block Diagrams

9. State Transition Diagrams

10. Technology

11. Functional Prototype

12. Testing

12.1. Testing Scenarios

Introduction
Driver drowsiness is a safety-critical problem, as it causes unsafe driving conditions by lowering reaction times, reducing attention, and impairing decision-making.

The Impact: An estimated 17.6% of fatal crashes in the United States from 2017 to 2021 involved a drowsy or tired driver, resulting in approximately 30,000 deaths during that period.

Our Solution: We are building a proactive system designed to reduce fatigue-related accidents.

How it Works: The system captures visual data of the driver and makes real-time inferences based on their body language. This keeps the driver in check, ensuring they are neither tired nor drowsy during their trip, which ultimately reduces mistakes.

Safety Precaution: Fleet operators are integrated into the system as an extra layer of precaution. If a driver is drowsy and fails to stop and rest, the fleet operator will intervene and remind the driver to pull over, preventing accidents and keeping the roads safe.

Need & Goal Statements
Need Statement
Vehicular accidents are caused by people feeling too drowsy/tired.

Goal Statement
Prevent people from driving while drowsy.

Technology
(Note: Content formatted into categories for easier reading)

Hardware & Processing

Custom PCB: The "brain" of the device acts as the central computer.

GPU: The PCB is equipped with a powerful GPU capable of hosting and running our real-time AI model.

Software & Artificial Intelligence

AI Model: Programmed using the Python programming language.

Framework: Utilizes Mediapipe for visual data processing and body language inferences.

Frontend & Notifications

User Interface: Notifications are pushed to a frontend application that operates seamlessly across Android, iOS, and the Web.

Development Framework: The app is built using Flutter, which utilizes the Dart programming language.

Dependencies: Compiling the app requires the Android SDK (for Android devices) and XCode (for iOS devices).
