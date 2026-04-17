"""
MODEL MANAGER
Loads and manages persistent ML models for Godot integration
"""

import joblib
import pandas as pd
import os
from typing import Dict, List

class ModelManager:
    def __init__(self, models_dir: str = "models"):
        self.models_dir = models_dir
        self.models = {}
        self.features = {}
        self._load_all_models()
    
    def _load_all_models(self):
        """Load all saved models from disk"""
        print("\n[ModelManager] Loading persistent ML models...")
        
        try:
            # Load Lane Change Model
            if os.path.exists(f"{self.models_dir}/model_lane_change.pkl"):
                self.models['lane_change'] = joblib.load(f"{self.models_dir}/model_lane_change.pkl")
                self.features['lane_change'] = joblib.load(f"{self.models_dir}/model_lane_change_features.pkl")
                print("  ✓ Loaded: Lane Change Model")
            
            # Load Turning Model
            if os.path.exists(f"{self.models_dir}/model_turning.pkl"):
                self.models['turning'] = joblib.load(f"{self.models_dir}/model_turning.pkl")
                self.features['turning'] = joblib.load(f"{self.models_dir}/model_turning_features.pkl")
                print("  ✓ Loaded: Turning Model")
            
            # Load V2V Chat Model
            if os.path.exists(f"{self.models_dir}/model_v2v_chat.pkl"):
                self.models['v2v_chat'] = joblib.load(f"{self.models_dir}/model_v2v_chat.pkl")
                self.features['v2v_chat'] = joblib.load(f"{self.models_dir}/model_v2v_chat_features.pkl")
                print("  ✓ Loaded: V2V Chat Model")
            
            if not self.models:
                print("  ⚠ WARNING: No models found. Run train_models.py first!")
                return False
            
            print(f"  ✓ {len(self.models)} models ready for inference\n")
            return True
            
        except Exception as e:
            print(f"  ✗ Error loading models: {e}")
            return False
    
    def predict_lane_change(self, car_state: Dict) -> Dict:
        """
        Predict lane change decision for a car
        
        Args:
            car_state: {
                'speed': float,
                'urgency': float (0-1),
                'aggressiveness': float (0-1),
                'rel_target': int (-2 to +2),
                'perceived_gap': int (0 or 1)
            }
        
        Returns:
            {
                'decision': str ('MERGE' or 'WAIT'),
                'confidence': float (0-1),
                'target_lane': int or None,
                'model': str
            }
        """
        try:
            if 'lane_change' not in self.models:
                return {'error': 'Lane change model not loaded'}
            
            model = self.models['lane_change']
            features = self.features['lane_change']
            
            # Build feature vector
            df = pd.DataFrame([car_state])
            df = df[features]  # Ensure correct order
            
            # Predict
            prediction = model.predict(df)[0]
            probability = model.predict_proba(df)[0]
            
            return {
                'decision': 'MERGE' if prediction == 1 else 'WAIT',
                'confidence': float(max(probability)),
                'target_lane': car_state.get('target_lane', None),
                'model': 'lane_change',
                'raw_prediction': int(prediction)
            }
        
        except Exception as e:
            return {'error': str(e)}
    
    def predict_turning(self, car_state: Dict) -> Dict:
        """Predict turning decision (exit scenario)"""
        try:
            if 'turning' not in self.models:
                return {'error': 'Turning model not loaded'}
            
            model = self.models['turning']
            features = self.features['turning']
            
            df = pd.DataFrame([car_state])
            df = df[features]
            
            prediction = model.predict(df)[0]
            probability = model.predict_proba(df)[0]
            
            return {
                'decision': 'MERGE' if prediction == 1 else 'WAIT',
                'confidence': float(max(probability)),
                'model': 'turning',
                'raw_prediction': int(prediction)
            }
        
        except Exception as e:
            return {'error': str(e)}
    
    def predict_v2v_negotiation(self, car_state: Dict) -> Dict:
        """Predict V2V (vehicle-to-vehicle) negotiation decision"""
        try:
            if 'v2v_chat' not in self.models:
                return {'error': 'V2V Chat model not loaded'}
            
            model = self.models['v2v_chat']
            features = self.features['v2v_chat']
            
            df = pd.DataFrame([car_state])
            df = df[features]
            
            prediction = model.predict(df)[0]
            probability = model.predict_proba(df)[0]
            
            return {
                'decision': 'NEGOTIATE_MERGE' if prediction == 1 else 'HOLD_POSITION',
                'confidence': float(max(probability)),
                'model': 'v2v_chat',
                'raw_prediction': int(prediction)
            }
        
        except Exception as e:
            return {'error': str(e)}
    
    def batch_predict(self, scenario: str, car_states: List[Dict]) -> List[Dict]:
        """Batch predict for multiple cars"""
        predictions = []
        for car_state in car_states:
            if scenario == 'lane_change':
                pred = self.predict_lane_change(car_state)
            elif scenario == 'turning':
                pred = self.predict_turning(car_state)
            elif scenario == 'v2v':
                pred = self.predict_v2v_negotiation(car_state)
            else:
                pred = {'error': f'Unknown scenario: {scenario}'}
            
            predictions.append(pred)
        
        return predictions
    
    def get_model_info(self) -> Dict:
        """Get information about loaded models"""
        info = {}
        for model_name, model in self.models.items():
            info[model_name] = {
                'type': type(model).__name__,
                'features': self.features[model_name],
                'n_estimators': model.n_estimators,
                'max_depth': model.max_depth
            }
        return info


# Test when run directly
if __name__ == "__main__":
    manager = ModelManager()
    
    if manager.models:
        print("=" * 60)
        print("MODEL MANAGER - TEST PREDICTIONS")
        print("=" * 60)
        
        # Test car state
        test_car = {
            'speed': 15.5,
            'urgency': 0.75,
            'aggressiveness': 0.85,
            'rel_target': 1,
            'perceived_gap': 1,
            'target_lane': 3
        }
        
        print("\nTest Car State:", test_car)
        
        print("\n[Lane Change Model]")
        result = manager.predict_lane_change(test_car)
        print(f"  Decision: {result['decision']}")
        print(f"  Confidence: {result['confidence']:.2%}")
        
        print("\n[Turning Model]")
        result = manager.predict_turning(test_car)
        print(f"  Decision: {result['decision']}")
        print(f"  Confidence: {result['confidence']:.2%}")
        
        print("\n[V2V Chat Model]")
        result = manager.predict_v2v_negotiation(test_car)
        print(f"  Decision: {result['decision']}")
        print(f"  Confidence: {result['confidence']:.2%}")
        
        print("\n" + "=" * 60)
